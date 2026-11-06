using GLib;

// flock(2) is not in Vala's posix.vapi; bind it directly.
[CCode (cheader_filename = "sys/file.h")]
extern int flock(int fd, int operation);
private const int FLOCK_LOCK_EX = 2;
private const int FLOCK_LOCK_UN = 8;

namespace AppManager.Core {

    /**
     * On-demand manager for the /tmp symlinks the AnyLinux AppImage build
     * relies on for TLS. The bundled libgnutls / p11-kit / libgiognutls
     * are patched by quick-sharun to load libraries and module data from
     * byte-length-matched fixed paths like /tmp/<lib_token>. On a
     * multi-user host these collide because /tmp's sticky bit prevents
     * the second user from replacing the first user's symlinks, and the
     * underlying FUSE mount is user-private.
     *
     * Instead of creating the symlinks once at AppRun startup (the
     * quick-sharun default - neutralized in scripts/make-anyimage.sh),
     * we create them only around active network fetches and remove them
     * right after. A process-local refcount lets nested calls share one
     * set of symlinks; a /tmp flock serializes between AppManager
     * processes running as different users so only one user owns the
     * symlinks at a time.
     *
     * The trust module reads its CA bundle through a persistent per-user
     * link under XDG_CONFIG_HOME. Unlike the temporary library mappings,
     * that link must remain available to other AnyLinux applications.
     *
     * When APPDIR is unset (native install), every public method is a
     * no-op.
     */
    public class TlsSession : Object {
        public delegate void Scope() throws Error;

        private const string LOCK_FILE = "/tmp/.appmanager-tls.lock";

        private static string[] POSSIBLE_CA_BUNDLES = {
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/cert.pem",
            "/etc/pki/tls/cacert.pem",
            "/etc/ssl/cert.pem",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            "/var/lib/ca-certificates/ca-bundle.pem"
        };

        private static TlsSession? _instance = null;
        private static Mutex instance_mutex;

        public static TlsSession get_default() {
            instance_mutex.lock();
            if (_instance == null) {
                _instance = new TlsSession();
                // Reap our /tmp symlinks on any normal process exit (GUI
                // close, daemon stop, CLI one-shot) so a session that ends
                // before reaching release() - e.g. the window closed
                // mid-fetch - doesn't orphan them. Signals/crashes aren't
                // covered; cleanup_stale() reaps those next launch.
                Posix.atexit(at_exit_cleanup);
            }
            var instance = _instance;
            instance_mutex.unlock();
            return instance;
        }

        private static void at_exit_cleanup() {
            if (_instance != null && _instance.lock_fd >= 0) {
                _instance.remove_symlinks();
            }
        }

        private Mutex mutex = Mutex();
        private int refcount = 0;
        private int lock_fd = -1;
        private bool initialized = false;
        private string? tok_bin = null;
        private string? tok_lib = null;
        private string? tok_share = null;
        private string? host_ca_source = null;
        private bool nothing_to_do = false;

        public static void with_session(Scope scope) throws Error {
            var t = get_default();
            t.acquire();
            try {
                scope();
            } finally {
                t.release();
            }
        }

        /**
         * One-shot cleanup at app startup. Removes any of our own
         * symlinks left behind by a previous crash. Never blocks on
         * flock - best-effort.
         */
        public static void cleanup_stale() {
            get_default().do_cleanup_stale();
        }

        private void ensure_initialized() {
            if (initialized) return;
            initialized = true;

            var appdir = Environment.get_variable("APPDIR");
            if (appdir == null || appdir.strip() == "") {
                nothing_to_do = true;
                return;
            }

            var hook = Path.build_filename(appdir, "bin", "01-path-mapping-hardcoded.hook");
            string contents;
            try {
                if (FileUtils.get_contents(hook, out contents)) {
                    foreach (var line in contents.split("\n")) {
                        var t = line.strip();
                        if (t.has_prefix("_tmp_bin=")) {
                            tok_bin = trim_quotes(t.substring("_tmp_bin=".length));
                        } else if (t.has_prefix("_tmp_lib=")) {
                            tok_lib = trim_quotes(t.substring("_tmp_lib=".length));
                        } else if (t.has_prefix("_tmp_share=")) {
                            tok_share = trim_quotes(t.substring("_tmp_share=".length));
                        }
                    }
                }
            } catch (Error e) {
                // Missing hook is expected when APPDIR is set outside a finished
                // AppImage (e.g. quick-sharun tracing the binary mid-build).
                if (!(e is FileError.NOENT)) {
                    warning("TlsSession: cannot read %s: %s", hook, e.message);
                }
            }

            foreach (var p in POSSIBLE_CA_BUNDLES) {
                if (FileUtils.test(p, FileTest.IS_REGULAR)) {
                    host_ca_source = p;
                    break;
                }
            }

            if (tok_bin == null && tok_lib == null && tok_share == null) {
                nothing_to_do = true;
            }
        }

        private static string? trim_quotes(string s) {
            var x = s.strip();
            if (x.length >= 2 && x[0] == '"' && x[x.length - 1] == '"') {
                return x.substring(1, x.length - 2);
            }
            if (x.length >= 2 && x[0] == '\'' && x[x.length - 1] == '\'') {
                return x.substring(1, x.length - 2);
            }
            return x == "" ? null : x;
        }

        public void acquire() throws FileError {
            mutex.lock();
            try {
                ensure_initialized();
                if (refcount == 0 && host_ca_source != null) {
                    ensure_host_ca_link(host_ca_source);
                }
                if (!nothing_to_do && refcount == 0) {
                    lock_fd = open_lock_file(LOCK_FILE);
                    int result = -1;
                    do {
                        result = flock(lock_fd, FLOCK_LOCK_EX);
                    } while (result != 0 && Posix.errno == Posix.EINTR);
                    if (result != 0) {
                        int err = Posix.errno;
                        Posix.close(lock_fd);
                        lock_fd = -1;
                        throw new FileError.FAILED(
                            "TlsSession: flock %s failed: %s", LOCK_FILE, Posix.strerror(err));
                    }
                    create_symlinks();
                }
                // Publish the session only after the lock and links are ready.
                refcount++;
            } finally {
                mutex.unlock();
            }
        }

        internal static int open_lock_file(string path) throws FileError {
            // flock needs no write access. Never use O_CREAT on an existing
            // foreign-owned /tmp file: Linux protected_regular rejects it.
            int flags = Posix.O_RDONLY | Posix.O_CLOEXEC | Posix.O_NOFOLLOW | Posix.O_NONBLOCK;
            int fd = Posix.open(path, flags | Posix.O_CREAT | Posix.O_EXCL, 0644);
            if (fd >= 0) {
                // Keep it readable by other users even with a private umask.
                if (Posix.fchmod(fd, 0644) != 0) {
                    int err = Posix.errno;
                    Posix.close(fd);
                    throw new FileError.FAILED(
                        "TlsSession: chmod %s failed: %s", path, Posix.strerror(err));
                }
            } else if (Posix.errno == Posix.EEXIST) {
                fd = Posix.open(path, flags);
            }
            if (fd < 0) {
                int err = Posix.errno;
                throw new FileError.FAILED(
                    "TlsSession: open %s failed: %s", path, Posix.strerror(err));
            }
            Posix.Stat st;
            if (Posix.fstat(fd, out st) != 0 || !Posix.S_ISREG(st.st_mode)) {
                Posix.close(fd);
                throw new FileError.INVAL("TlsSession: %s is not a regular lock file", path);
            }
            return fd;
        }

        public void release() {
            mutex.lock();
            if (refcount == 0) {
                mutex.unlock();
                warning("TlsSession: release() with zero refcount");
                return;
            }
            refcount--;
            if (!nothing_to_do && refcount == 0) {
                remove_symlinks();

                flock(lock_fd, FLOCK_LOCK_UN);
                Posix.close(lock_fd);
                lock_fd = -1;
            }
            mutex.unlock();
        }

        private void create_symlinks() {
            var appdir = Environment.get_variable("APPDIR");
            if (appdir == null) return;

            create_link(Path.build_filename(appdir, "bin"), tok_bin);
            create_link(Path.build_filename(appdir, "lib"), tok_lib);
            create_link(Path.build_filename(appdir, "share"), tok_share);
        }

        private void ensure_host_ca_link(string source) throws FileError {
            // quick-sharun changed p11-kit-trust.so's patched trust path in
            // September 2026. Creating the old /tmp link leaves it empty (#209).
            var directory = Path.build_filename(Environment.get_user_config_dir(), "anylinux-ca");
            var link = Path.build_filename(directory, "trust-anchors.pem");
            // Keep an existing usable bundle, including user-managed CA files.
            if (FileUtils.test(link, FileTest.IS_REGULAR)) return;
            if (DirUtils.create_with_parents(directory, 0700) != 0) {
                throw new FileError.FAILED("TlsSession: mkdir %s failed: %s",
                                          directory, Posix.strerror(Posix.errno));
            }
            if (Posix.symlink(source, link) == 0) return;
            int link_error = Posix.errno;
            if (link_error != Posix.EEXIST || !FileUtils.test(link, FileTest.IS_SYMLINK)) {
                throw new FileError.FAILED("TlsSession: symlink %s failed: %s",
                                          link, Posix.strerror(link_error));
            }
            // Repair a dangling link atomically so another process never sees
            // the trust path disappear while it is loading its CA database.
            var temporary = Path.build_filename(directory, ".trust-anchors-" + Uuid.string_random());
            if (Posix.symlink(source, temporary) != 0) {
                throw new FileError.FAILED("TlsSession: symlink %s failed: %s",
                                          temporary, Posix.strerror(Posix.errno));
            }
            if (FileUtils.rename(temporary, link) != 0) {
                int err = Posix.errno;
                Posix.unlink(temporary);
                throw new FileError.FAILED("TlsSession: rename %s failed: %s",
                                          link, Posix.strerror(err));
            }
        }

        private void create_link(string target, string? token) {
            if (token == null || token == "") return;
            create_link_at(target, "/tmp/" + token);
        }

        private void create_link_at(string target, string link) {
            Posix.Stat st;
            if (Posix.lstat(link, out st) == 0) {
                if (Posix.S_ISLNK(st.st_mode)) {
                    try {
                        var cur = FileUtils.read_link(link);
                        if (cur == target) {
                            return;
                        }
                    } catch (Error e) {
                        // fall through and try to replace
                    }
                }
                if (st.st_uid == Posix.getuid()) {
                    if (Posix.unlink(link) != 0) {
                        warning("TlsSession: unlink %s failed: %s",
                                link, Posix.strerror(Posix.errno));
                        return;
                    }
                } else {
                    warning("TlsSession: %s is owned by another user (uid %u); TLS may fail until they release it",
                            link, (uint) st.st_uid);
                    return;
                }
            }
            if (Posix.symlink(target, link) != 0) {
                warning("TlsSession: symlink(%s -> %s) failed: %s",
                        link, target, Posix.strerror(Posix.errno));
            }
        }

        private void remove_symlinks() {
            unlink_if_owned(tmp_path_for(tok_bin));
            unlink_if_owned(tmp_path_for(tok_lib));
            unlink_if_owned(tmp_path_for(tok_share));
        }

        private static string? tmp_path_for(string? token) {
            if (token == null || token == "") return null;
            return "/tmp/" + token;
        }

        private static void unlink_if_owned(string? path) {
            if (path == null) return;
            Posix.Stat st;
            if (Posix.lstat(path, out st) != 0) return;
            if (st.st_uid != Posix.getuid()) return;
            Posix.unlink(path);
        }

        private void do_cleanup_stale() {
            mutex.lock();
            ensure_initialized();
            if (!nothing_to_do && refcount == 0) {
                unlink_if_stale_and_owned(tmp_path_for(tok_bin));
                unlink_if_stale_and_owned(tmp_path_for(tok_lib));
                unlink_if_stale_and_owned(tmp_path_for(tok_share));
            }
            mutex.unlock();
        }

        private static void unlink_if_stale_and_owned(string? path) {
            if (path == null) return;
            Posix.Stat lst;
            if (Posix.lstat(path, out lst) != 0) return;
            if (!Posix.S_ISLNK(lst.st_mode)) return;
            if (lst.st_uid != Posix.getuid()) return;
            Posix.Stat tst;
            if (Posix.stat(path, out tst) != 0) {
                Posix.unlink(path);
            }
        }
    }
}
