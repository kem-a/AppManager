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
     * are patched by quick-sharun to read CA store + PKCS#11 trust from
     * byte-length-matched fixed paths like /tmp/<lib_token>. On a
     * multi-user host these collide because /tmp's sticky bit prevents
     * the second user from replacing the first user's symlinks, and the
     * underlying FUSE mount is user-private.
     *
     * Instead of creating the symlinks once at AppRun startup (the
     * quick-sharun default — neutralized in scripts/make-anyimage.sh),
     * we create them only around active network fetches and remove them
     * right after. A process-local refcount lets nested calls share one
     * set of symlinks; a /tmp flock serializes between AppManager
     * processes running as different users so only one user owns the
     * symlinks at a time.
     *
     * When APPDIR is unset (native install), every public method is a
     * no-op.
     */
    public class TlsSession : Object {
        public delegate void Scope() throws Error;

        private const string LOCK_FILE = "/tmp/.appmanager-tls.lock";
        private const string HOST_CERTS_DIR = "/tmp/.___host-certs";
        private const string HOST_CERTS_LINK = "/tmp/.___host-certs/ca-certificates.crt";

        private static string[] POSSIBLE_CA_BUNDLES = {
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/cert.pem",
            "/etc/pki/tls/cacert.pem",
            "/etc/ssl/cert.pem",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            "/var/lib/ca-certificates/ca-bundle.pem"
        };

        private static TlsSession? _instance = null;

        public static TlsSession get_default() {
            if (_instance == null) {
                _instance = new TlsSession();
                // Reap our /tmp symlinks on any normal process exit (GUI
                // close, daemon stop, CLI one-shot) so a session that ends
                // before reaching release() — e.g. the window closed
                // mid-fetch — doesn't orphan them. Signals/crashes aren't
                // covered; cleanup_stale() reaps those next launch.
                Posix.atexit(at_exit_cleanup);
            }
            return _instance;
        }

        private static void at_exit_cleanup() {
            if (_instance != null) {
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
         * flock — best-effort.
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
                warning("TlsSession: cannot read %s: %s", hook, e.message);
            }

            foreach (var p in POSSIBLE_CA_BUNDLES) {
                if (FileUtils.test(p, FileTest.IS_REGULAR)) {
                    host_ca_source = p;
                    break;
                }
            }

            if (tok_bin == null && tok_lib == null && tok_share == null && host_ca_source == null) {
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

        public void acquire() {
            ensure_initialized();

            mutex.lock();
            refcount++;
            bool first = (refcount == 1);
            mutex.unlock();

            if (nothing_to_do || !first) return;

            lock_fd = Posix.open(LOCK_FILE, Posix.O_CREAT | Posix.O_RDWR, 0666);
            if (lock_fd < 0) {
                warning("TlsSession: open %s failed: %s",
                        LOCK_FILE, Posix.strerror(Posix.errno));
            } else if (flock(lock_fd, FLOCK_LOCK_EX) != 0) {
                warning("TlsSession: flock %s failed: %s",
                        LOCK_FILE, Posix.strerror(Posix.errno));
                Posix.close(lock_fd);
                lock_fd = -1;
            }

            create_symlinks();
        }

        public void release() {
            mutex.lock();
            if (refcount == 0) {
                mutex.unlock();
                warning("TlsSession: release() with zero refcount");
                return;
            }
            refcount--;
            bool last = (refcount == 0);
            mutex.unlock();

            if (nothing_to_do || !last) return;

            remove_symlinks();

            if (lock_fd >= 0) {
                flock(lock_fd, FLOCK_LOCK_UN);
                Posix.close(lock_fd);
                lock_fd = -1;
            }
        }

        private void create_symlinks() {
            var appdir = Environment.get_variable("APPDIR");
            if (appdir == null) return;

            create_link(Path.build_filename(appdir, "bin"), tok_bin);
            create_link(Path.build_filename(appdir, "lib"), tok_lib);
            create_link(Path.build_filename(appdir, "share"), tok_share);

            if (host_ca_source != null) {
                DirUtils.create_with_parents(HOST_CERTS_DIR, 0777);
                Posix.chmod(HOST_CERTS_DIR, 0777);
                create_link_at(host_ca_source, HOST_CERTS_LINK);
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
            unlink_if_owned(HOST_CERTS_LINK);
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
            ensure_initialized();
            if (nothing_to_do) return;

            unlink_if_stale_and_owned(tmp_path_for(tok_bin));
            unlink_if_stale_and_owned(tmp_path_for(tok_lib));
            unlink_if_stale_and_owned(tmp_path_for(tok_share));
            unlink_if_stale_and_owned(HOST_CERTS_LINK);
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
