namespace AppManager.Core {
    /**
     * Keeps a suspend from deadlocking on the app's FUSE mount.
     *
     * Suspend freezes every process at once. An app caught waiting for its FUSE
     * driver (squashfuse or dwarfs), itself already frozen, sits in an
     * uninterruptible wait and cannot be frozen. The suspend fails, and logind
     * retries for as long as the lid stays closed.
     *
     * An app freezes fine while its driver still runs, so the order is made here:
     * the app gets a systemd scope of its own, away from the driver, and that scope
     * is frozen under a logind delay lock before the suspend freezes the rest.
     *
     * Best effort throughout: without a systemd user manager or logind the app runs
     * as it did before, unguarded.
     */
    public class SandboxSuspendGuard {
        private const string SYSTEMD = "org.freedesktop.systemd1";
        private const string SYSTEMD_PATH = "/org/freedesktop/systemd1";
        private const string SYSTEMD_MANAGER = "org.freedesktop.systemd1.Manager";
        private const string LOGIND = "org.freedesktop.login1";
        private const string LOGIND_PATH = "/org/freedesktop/login1";
        private const string LOGIND_MANAGER = "org.freedesktop.login1.Manager";

        // Calls never start a service: if systemd or logind is not there already,
        // there is nothing to guard with. A launch must not hang on a mute bus either.
        private const int CALL_TIMEOUT_MS = 2000;
        // Kept back from logind's delay limit for the freeze itself. A cold dwarfs
        // cache needed up to 212 ms for the app to settle.
        private const int64 FREEZE_MARGIN_USEC = 1000000;
        private const int FREEZE_TIMEOUT_MS = 900;
        private const ulong POLL_USEC = 50000;

        private string scope;
        private DBusConnection session_bus;
        private DBusConnection? system_bus = null;
        private MainContext context = new MainContext();
        private MainLoop loop;
        private Thread<void>? thread = null;
        private int lock_fd = -1;
        private int64 max_delay_usec = 0;
        private bool frozen = false;

        private SandboxSuspendGuard(DBusConnection session_bus, string scope) {
            this.session_bus = session_bus;
            this.scope = scope;
            loop = new MainLoop(context);
        }

        /**
         * Moves `pid` into a scope of its own and starts guarding it. The caller
         * holds `pid` back from exec until this returns, so nothing it forks is
         * left behind in the launch scope. Returns null when there is nothing to
         * guard with.
         */
        public static SandboxSuspendGuard? start(Posix.pid_t pid, string app_id) {
            string own_unit, slice;
            if (!own_cgroup(out own_unit, out slice)) {
                return null;
            }
            var scope = scope_name(own_unit, app_id, (int) pid);
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                // GLib would end this process, and the app with it, when a bus closes.
                bus.set_exit_on_close(false);
                var props = new VariantBuilder(new VariantType("a(sv)"));
                props.add("(sv)", "PIDs",
                    new Variant.array(VariantType.UINT32, { new Variant.uint32((uint32) pid) }));
                // A failed scope would otherwise keep its name taken.
                props.add("(sv)", "CollectMode", new Variant.string("inactive-or-failed"));
                if (slice != "") {
                    props.add("(sv)", "Slice", new Variant.string(slice));
                }
                bus.call_sync(SYSTEMD, SYSTEMD_PATH, SYSTEMD_MANAGER, "StartTransientUnit",
                    new Variant("(ss@a(sv)@a(sa(sv)))", scope, "fail", props.end(),
                        new Variant.array(new VariantType("(sa(sv))"), new Variant[0])),
                    null, DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS);
                // The call only queues the job; the move itself follows.
                for (int i = 0; i < 200 && !in_scope(pid, scope); i++) {
                    Thread.usleep(5000);
                }
                if (!in_scope(pid, scope)) {
                    debug("Sandbox: %d never reached %s", (int) pid, scope);
                    return null;
                }
                var guard = new SandboxSuspendGuard(bus, scope);
                guard.thread = new Thread<void>("suspend-guard", guard.run);
                return guard;
            } catch (Error e) {
                debug("Sandbox: no suspend guard: %s", e.message);
                return null;
            }
        }

        /**
         * Ends the guard once the app has exited.
         */
        public void stop() {
            context.invoke(() => {
                loop.quit();
                return Source.REMOVE;
            });
            thread.join();
            if (frozen) {
                call_unit("ThawUnit");
            }
            release_lock();
        }

        /**
         * Desktops name app scopes "app-<launcher>-<id>-<pid>.scope" and portals read
         * the app id back from that, so a launch scope's id is carried over.
         */
        internal static string scope_name(string own_unit, string app_id, int pid) {
            string prefix;
            if (Regex.match_simple("^app-.+-[0-9]+\\.scope$", own_unit)) {
                prefix = own_unit.substring(0, own_unit.last_index_of_char('-'));
            } else {
                var escaped = new StringBuilder();
                for (int i = 0; i < app_id.length; i++) {
                    var c = app_id[i];
                    if (c.isalnum() || c == ':' || c == '_' || c == '.') {
                        escaped.append_c(c);
                    } else {
                        escaped.append_printf("\\x%02x", (uint8) c);
                    }
                }
                prefix = "app-appmanager-" + escaped.str;
            }
            return "%s-%d.scope".printf(prefix, pid);
        }

        // This process's unit, and its slice when the user manager owns it.
        private static bool own_cgroup(out string unit, out string slice) {
            unit = "";
            slice = "";
            string contents;
            try {
                GLib.FileUtils.get_contents("/proc/self/cgroup", out contents);
            } catch (FileError e) {
                return false;
            }
            if (!contents.has_prefix("0::/")) {
                return false;  // not cgroup v2
            }
            var path = contents.substring(3).strip();
            unit = Path.get_basename(path);
            var parent = Path.get_basename(Path.get_dirname(path));
            if (path.contains("/user@") && parent.has_suffix(".slice")) {
                slice = parent;
            }
            return true;
        }

        private static bool in_scope(Posix.pid_t pid, string scope) {
            string contents;
            try {
                GLib.FileUtils.get_contents("/proc/%d/cgroup".printf((int) pid), out contents);
            } catch (FileError e) {
                return false;
            }
            return contents.strip().has_suffix("/" + scope);
        }

        private void run() {
            context.push_thread_default();
            uint subscription = 0;
            try {
                system_bus = Bus.get_sync(BusType.SYSTEM);
                system_bus.set_exit_on_close(false);
                var reply = system_bus.call_sync(LOGIND, LOGIND_PATH, "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", LOGIND_MANAGER, "InhibitDelayMaxUSec"),
                    new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS);
                Variant value;
                reply.get("(v)", out value);
                max_delay_usec = (int64) value.get_uint64();
                // Subscribed before the lock is taken, so no suspend slips between.
                subscription = system_bus.signal_subscribe(LOGIND, LOGIND_MANAGER, "PrepareForSleep",
                    LOGIND_PATH, null, DBusSignalFlags.NONE,
                    (connection, sender, path, iface, name, parameters) => {
                        bool sleeping;
                        parameters.get("(b)", out sleeping);
                        if (sleeping) {
                            on_sleep();
                        } else {
                            on_resume();
                        }
                    });
                bool busy;
                if (take_lock(out busy) || busy) {
                    loop.run();
                }
            } catch (Error e) {
                debug("Sandbox: suspend guard inactive: %s", e.message);
            }
            if (subscription != 0) {
                system_bus.signal_unsubscribe(subscription);
            }
            context.pop_thread_default();
        }

        private void on_sleep() {
            if (!frozen) {
                // An app handles the suspend itself under a delay lock of its own
                // (Electron does). Freezing sooner would cut that short and leave
                // its lock held until logind's limit.
                int64 deadline = get_monotonic_time() + max_delay_usec - FREEZE_MARGIN_USEC;
                while (app_holds_delay_lock() && get_monotonic_time() < deadline) {
                    Thread.usleep(POLL_USEC);
                }
                frozen = call_unit("FreezeUnit");
            }
            release_lock();
        }

        private void on_resume() {
            bool busy;
            // A failed suspend is retried at once while the lid stays closed, and
            // logind hands out no delay locks meanwhile. Staying frozen lets that
            // retry succeed; the resume that follows it thaws.
            if (!take_lock(out busy) && busy) {
                return;
            }
            if (frozen) {
                call_unit("ThawUnit");
                frozen = false;
            }
        }

        private bool take_lock(out bool busy) {
            busy = false;
            try {
                UnixFDList fds;
                var reply = system_bus.call_with_unix_fd_list_sync(LOGIND, LOGIND_PATH, LOGIND_MANAGER, "Inhibit",
                    new Variant("(ssss)", "sleep", "AppManager",
                        "Pause a sandboxed app ahead of its FUSE mount", "delay"),
                    new VariantType("(h)"), DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS, null, out fds);
                int32 handle;
                reply.get("(h)", out handle);
                release_lock();
                lock_fd = fds.get(handle);
                return true;
            } catch (Error e) {
                busy = DBusError.get_remote_error(e) == LOGIND + ".OperationInProgress";
                debug("Sandbox: no suspend delay lock: %s", e.message);
                return false;
            }
        }

        private void release_lock() {
            if (lock_fd >= 0) {
                Posix.close(lock_fd);
                lock_fd = -1;
            }
        }

        private bool app_holds_delay_lock() {
            try {
                var reply = system_bus.call_sync(LOGIND, LOGIND_PATH, LOGIND_MANAGER, "ListInhibitors",
                    null, new VariantType("(a(ssssuu))"), DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS);
                VariantIter inhibitors;
                reply.get("(a(ssssuu))", out inhibitors);
                string what, who, why, mode;
                uint32 uid, pid;
                while (inhibitors.next("(ssssuu)", out what, out who, out why, out mode, out uid, out pid)) {
                    if (mode == "delay" && what.contains("sleep") && belongs_to_app(pid)) {
                        return true;
                    }
                }
            } catch (Error e) {
                debug("Sandbox: cannot list inhibitors: %s", e.message);
            }
            return false;
        }

        private bool belongs_to_app(uint32 pid) {
            if (in_scope((Posix.pid_t) pid, scope)) {
                return true;
            }
            // Behind the filtered bus logind sees the proxy, a child of this process.
            string stat;
            try {
                GLib.FileUtils.get_contents("/proc/%u/stat".printf(pid), out stat);
            } catch (FileError e) {
                return false;
            }
            // "pid (comm) state ppid ...": comm may itself hold spaces and brackets.
            var fields = stat.substring(stat.last_index_of_char(')') + 1).strip().split(" ");
            return fields.length > 1 && int.parse(fields[1]) == (int) Posix.getpid();
        }

        private bool call_unit(string method) {
            try {
                session_bus.call_sync(SYSTEMD, SYSTEMD_PATH, SYSTEMD_MANAGER, method,
                    new Variant("(s)", scope), null, DBusCallFlags.NO_AUTO_START, FREEZE_TIMEOUT_MS);
                return true;
            } catch (Error e) {
                debug("Sandbox: %s %s: %s", method, scope, e.message);
                // A freeze still under way has to be undone on resume all the same.
                return e is IOError.TIMED_OUT;
            }
        }
    }
}
