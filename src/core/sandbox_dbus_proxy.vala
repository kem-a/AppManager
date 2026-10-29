namespace AppManager.Core {
    /**
     * An xdg-dbus-proxy instance standing between a sandboxed app and the message
     * buses, plus the rule set it enforces.
     *
     * The app never gets the real bus socket. It gets a socket this proxy listens on,
     * and the proxy forwards only what the rules allow. One process serves both buses:
     * the session bus for desktop services, the system bus for BlueZ and GeoClue2.
     *
     * Two descriptors do the coordination, both copied from what flatpak does:
     *
     *  - The **sync pipe**. The proxy holds the write end (--fd) and writes a single
     *    byte once it is listening; the supervisor blocks on the read end before
     *    starting the app, so the app can never race ahead of its own bus. The read end
     *    is then handed to the app's bwrap (--sync-fd), which holds it open for the
     *    sandbox's lifetime - so when the app dies the pipe closes and the proxy exits
     *    on its own. No supervision of the proxy is needed beyond that.
     *
     *  - The **args pipe** (--args), carrying the addresses and rules NUL-separated.
     *    Passing them this way keeps a long, revealing rule list out of
     *    /proc/<pid>/cmdline, where every process on the machine can read it.
     */
    public class SandboxDbusProxy {
        public string? session_socket { get; private set; default = null; }
        public string? system_socket { get; private set; default = null; }
        public string? a11y_socket { get; private set; default = null; }
        // Set when the sockets live in a directory of this launch's own. See prepare().
        public string? socket_dir { get; private set; default = null; }
        // The end to hand to the app's bwrap as --sync-fd.
        public int sync_read_fd { get; private set; default = -1; }

        private Posix.pid_t pid = 0;
        private SandboxManifest manifest;
        private string proxy_path;
        private string? session_address = null;
        private string? a11y_address = null;
        private int sync_write_fd = -1;

        /**
         * Starts a proxy for `manifest`. Returns null when the proxy cannot be started,
         * which the supervisor turns into a fail-closed refusal: an app expecting a
         * filtered bus must not silently get none.
         *
         * `instance_id` names the sockets, so that concurrent launches of the same app
         * do not collide.
         */
        public static SandboxDbusProxy? start(SandboxManifest manifest, string instance_id) {
            var self = prepare(manifest, instance_id, false);
            return (self != null && self.launch(0)) ? self : null;
        }

        /**
         * Everything short of forking the proxy: socket paths, bus addresses and the
         * sync pipe. With `own_dir` the sockets go in a directory of their own, which
         * bwrap can bind before the proxy has created them. That lets a launch whose
         * app shares the host's pids start bwrap first and call launch() with the pid.
         */
        public static SandboxDbusProxy? prepare(SandboxManifest manifest, string instance_id, bool own_dir) {
            var proxy_path = AppPaths.xdg_dbus_proxy_path;
            if (proxy_path == null) {
                return null;
            }

            var socket_dir = Path.build_filename(AppPaths.sandbox_runtime_dir, "dbusproxy");
            var prefix = instance_id + "-";
            if (own_dir) {
                socket_dir = Path.build_filename(socket_dir, instance_id);
                prefix = "";
            }
            if (DirUtils.create_with_parents(socket_dir, 0700) != 0) {
                warning("Sandbox: cannot create %s: %s", socket_dir, Posix.strerror(Posix.errno));
                return null;
            }

            var self = new SandboxDbusProxy();
            self.manifest = manifest;
            self.proxy_path = proxy_path;
            if (own_dir) {
                self.socket_dir = socket_dir;
            }
            if (manifest.needs_session_bus()) {
                self.session_address = host_session_bus_address();
                if (self.session_address == null) {
                    warning("Sandbox: no session bus address to proxy");
                    self.stop();
                    return null;
                }
                self.session_socket = Path.build_filename(socket_dir, prefix + "session");
            }
            if (manifest.needs_system_bus()) {
                self.system_socket = Path.build_filename(socket_dir, prefix + "system");
            }
            self.a11y_address = manifest.accessibility && !manifest.full_session_bus ? a11y_bus_address() : null;
            if (self.a11y_address != null) {
                self.a11y_socket = Path.build_filename(socket_dir, prefix + "a11y");
            }

            // A leftover socket from a supervisor that was killed would make bind fail.
            unlink_if_present(self.session_socket);
            unlink_if_present(self.system_socket);
            unlink_if_present(self.a11y_socket);

            int[] sync_fds = new int[2];
            if (Posix.pipe(sync_fds) != 0) {
                warning("Sandbox: cannot create bus proxy sync pipe: %s", Posix.strerror(Posix.errno));
                self.stop();
                return null;
            }
            // Only the proxy may hold the write end, and only bwrap the read end:
            // anything else spawned meanwhile must not inherit either.
            set_cloexec(sync_fds[0]);
            set_cloexec(sync_fds[1]);
            self.sync_read_fd = sync_fds[0];
            self.sync_write_fd = sync_fds[1];
            return self;
        }

        /**
         * Forks the proxy and waits until it listens. `app_pid` is the app's host pid
         * when it shares the host's pids, else 0. Stops and cleans up on failure.
         */
        public bool launch(int app_pid) {
            var args = new Gee.ArrayList<string>();
            if (session_socket != null) {
                args.add(session_address);
                args.add(session_socket);
                args.add("--filter");
                args.add_all(session_rules(manifest, app_pid));
            }

            if (system_socket != null) {
                args.add(Environment.get_variable("DBUS_SYSTEM_BUS_ADDRESS") ?? "unix:path=/run/dbus/system_bus_socket");
                args.add(system_socket);
                args.add("--filter");
                args.add_all(system_rules(manifest));
            }

            if (a11y_socket != null) {
                args.add(a11y_address);
                args.add(a11y_socket);
                args.add("--filter");
                // Required, not cosmetic: at-spi addresses the registry by its unique
                // name, and without this the proxy never reports those name changes, so
                // none of the rules below can match.
                args.add("--sloppy-names");
                args.add_all(a11y_rules());
            }

            int args_fd = SandboxBwrap.content_fd(nul_separated(args));
            if (args_fd < 0) {
                stop();
                return false;
            }

            var argv = build_argv(proxy_path, sync_write_fd, args_fd);

            var child = Posix.fork();
            if (child < 0) {
                warning("Sandbox: cannot fork the bus proxy: %s", Posix.strerror(Posix.errno));
                Posix.close(args_fd);
                stop();
                return false;
            }
            if (child == 0) {
                clear_cloexec(sync_write_fd);
                clear_cloexec(args_fd);
                Posix.close(sync_read_fd);
                Posix.execvp(argv[0], argv);
                Posix.perror(argv[0]);
                Posix._exit(127);
            }

            pid = child;
            Posix.close(args_fd);
            // Our own copy of the write end has to go before the read below, or a proxy
            // that dies on startup would leave the read blocking on a pipe this process
            // is itself holding open.
            Posix.close(sync_write_fd);
            sync_write_fd = -1;

            uint8[] ready = new uint8[1];
            ssize_t got;
            while ((got = Posix.read(sync_read_fd, ready, 1)) < 0 && Posix.errno == Posix.EINTR) {
                // Retry: a signal arriving during startup is not a failure.
            }
            if (got != 1) {
                warning("Sandbox: the bus proxy did not come up");
                stop();
                return false;
            }
            return true;
        }

        /**
         * Closes this process's copy of the sync pipe's read end. Must be called once
         * the app's bwrap has been forked and inherited it: while the supervisor still
         * holds a copy, the proxy cannot notice the app going away.
         */
        public void detach_sync_fd() {
            if (sync_read_fd >= 0) {
                Posix.close(sync_read_fd);
                sync_read_fd = -1;
            }
        }

        /**
         * Reaps the proxy. It normally exits by itself when the app's sandbox drops the
         * sync pipe, so this mostly just collects the corpse; a proxy still running
         * after the app is gone is asked to leave. Also undoes a prepare() that was
         * never launched.
         */
        public void stop() {
            if (pid > 0) {
                int status;
                if (Posix.waitpid(pid, out status, Posix.WNOHANG) == 0) {
                    Posix.kill(pid, Posix.Signal.TERM);
                    while (Posix.waitpid(pid, out status, 0) < 0 && Posix.errno == Posix.EINTR) {
                        // Retry.
                    }
                }
                pid = 0;
            }
            detach_sync_fd();
            if (sync_write_fd >= 0) {
                Posix.close(sync_write_fd);
                sync_write_fd = -1;
            }
            unlink_if_present(session_socket);
            unlink_if_present(system_socket);
            unlink_if_present(a11y_socket);
            if (socket_dir != null) {
                DirUtils.remove(socket_dir);
            }
        }

        /**
         * The proxy's command line. Nothing wraps it: the proxy is our own code doing
         * our own filtering, and it needs the host's own view of the buses it stands
         * in front of.
         */
        private static string[] build_argv(string proxy_path, int sync_fd, int args_fd) {
            return new string[] {
                proxy_path,
                "--fd=%d".printf(sync_fd),
                "--args=%d".printf(args_fd),
                null
            };
        }

        /**
         * Session-bus rules. Everything not listed is refused, including the services
         * that make sandbox escape trivial - systemd's StartTransientUnit above all.
         */
        public static Gee.ArrayList<string> session_rules(SandboxManifest manifest, int app_pid = 0) {
            var rules = new Gee.ArrayList<string>();
            add_exact_rules(rules, manifest.session_rules);

            // The app has to be able to claim its own bus name: a GApplication whose
            // name request is refused decides it is a secondary instance and quits.
            // Both the exact name and its namespace are granted: the wildcard alone
            // does not match the exact name, and the exact name alone refuses helpers
            // that publish under a sub-name.
            foreach (var name in manifest.own_names) {
                rules.add("--own=" + name);
                rules.add("--own=%s.*".printf(name));
            }

            if (manifest.notifications) {
                rules.add("--talk=org.freedesktop.Notifications");
            }

            if (manifest.tray) {
                rules.add("--talk=org.kde.StatusNotifierWatcher");
                rules.add_all(status_notifier_item_names(app_pid));
            }
            if (manifest.media_controls) {
                foreach (var name in manifest.media_names) {
                    rules.add("--own=" + name);
                    if (!name.has_suffix(".*")) rules.add("--own=" + name + ".*");
                }
            }
            if (manifest.keyring) {
                foreach (var name in KEYRING_NAMES) rules.add("--talk=" + name);
            }
            if (manifest.online_accounts) {
                foreach (var name in ONLINE_ACCOUNTS_NAMES) rules.add("--talk=" + name);
                rules.add("--talk=%s.*".printf(EVOLUTION_DATASERVER_NAMESPACE));
            }
            if (manifest.screenshots) {
                rules.add_all(screenshot_rules());
            }
            rules.add_all(settings_portal_rules());
            rules.add_all(screen_lock_rules());
            rules.add_all(app_menu_rules());
            rules.add_all(file_manager_rules());

            return rules;
        }

        /**
         * "Show in folder" for every app (GIMP, Chromium and Electron apps): the file
         * manager opens a window or properties dialog at a path the app names, and
         * nothing comes back. Files in the private home have other host paths, so
         * only granted folders show the right place.
         */
        public static Gee.ArrayList<string> file_manager_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.FileManager1";
            const string path = "/org/freedesktop/FileManager1";
            foreach (var member in new string[] { "ShowItems", "ShowFolders", "ShowItemProperties" }) {
                rules.add("--call=%s=%s.%s@%s".printf(service, service, member, path));
            }
            return rules;
        }

        /**
         * Screen-lock state for every app: password managers such as Bitwarden lock
         * their vault when the screen locks. Reading the state and hearing it change,
         * plus GNOME's WakeUpScreen notice (Planify refreshes its day on it), never
         * Lock, SetActive or idle inhibition.
         */
        public static Gee.ArrayList<string> screen_lock_rules() {
            var rules = new Gee.ArrayList<string>();
            foreach (var name in new string[] { "org.gnome.ScreenSaver", "org.freedesktop.ScreenSaver" }) {
                var path = "/" + name.replace(".", "/");
                rules.add("--call=%s=%s.GetActive@%s".printf(name, name, path));
                rules.add("--broadcast=%s=%s.ActiveChanged@%s".printf(name, name, path));
            }
            rules.add("--broadcast=org.gnome.ScreenSaver=org.gnome.ScreenSaver.WakeUpScreen@/org/gnome/ScreenSaver");
            return rules;
        }

        /**
         * Global menu registration (KDE Plasma, Unity) for every app. Only the app's
         * own windows: GetMenuForWindow would reveal other apps' menus. The host then
         * calls the app's exported menu, which the proxy lets through like the tray's.
         */
        public static Gee.ArrayList<string> app_menu_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "com.canonical.AppMenu.Registrar";
            const string path = "/com/canonical/AppMenu/Registrar";
            foreach (var member in new string[] { "RegisterWindow", "UnregisterWindow" }) {
                rules.add("--call=%s=%s.%s@%s".printf(service, service, member, path));
            }
            return rules;
        }

        /**
         * The Settings portal alone, for every app: apps following Granite's pattern
         * (Planify) read the color scheme only here, and libadwaita gets live changes
         * through it. It exposes nothing the ro-bound dconf does not. As with
         * screenshot_rules, properties stay refused.
         */
        public static Gee.ArrayList<string> settings_portal_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.portal.Desktop";
            const string path = "/org/freedesktop/portal/desktop";
            rules.add("--call=%s=org.freedesktop.portal.Settings.*@%s".printf(service, path));
            rules.add("--broadcast=%s=org.freedesktop.portal.Settings.SettingChanged@%s".printf(service, path));
            return rules;
        }

        /**
         * The Screenshot portal alone. The portal sees this proxy, a host process, so
         * it returns the plain file path rather than a document-portal one. Properties
         * stay refused: GTK reads the FileChooser and OpenURI versions from them and
         * would switch to portals this proxy refuses, with no fallback.
         */
        public static Gee.ArrayList<string> screenshot_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.portal.Desktop";
            const string path = "/org/freedesktop/portal/desktop";
            rules.add("--call=%s=org.freedesktop.portal.Screenshot.*@%s".printf(service, path));
            rules.add("--call=%s=org.freedesktop.portal.Request.Close@%s/request/*".printf(service, path));
            return rules;
        }

        // Secret Service (GNOME Keyring, KeePassXC, recent KWallet), the KWallet
        // names Chromium and Electron call directly, and the GNOME Keyring prompter
        // for unlock and passphrase dialogs (Convey does not start without it).
        // Whole-service grants: the proxy cannot filter on call arguments, so
        // per-item access is not expressible.
        public const string[] KEYRING_NAMES = {
            "org.freedesktop.secrets",
            "org.kde.kwalletd5",
            "org.kde.kwalletd6",
            "org.gnome.keyring.SystemPrompter"
        };

        // GNOME Online Accounts plus the services Convey (and other GOA-backed mail
        // and calendar apps) use: Contacts for contact cards and Settings to open
        // the Online Accounts panel. Evolution Data Server is a namespace because
        // its versioned service names change between releases. Whole services: the
        // proxy cannot filter on call arguments, and GOA returns credentials for
        // every configured account.
        public const string[] ONLINE_ACCOUNTS_NAMES = {
            "org.gnome.OnlineAccounts",
            "org.gnome.Contacts",
            "org.gnome.Settings"
        };
        public const string EVOLUTION_DATASERVER_NAMESPACE = "org.gnome.evolution.dataserver";

        // How far to enumerate tray-item names from the app's own pid. A few pids
        // cover an Electron app whose tray lives in a forked helper, and a couple of
        // item ids cover an app with more than one indicator.
        private const int SNI_PID_SPAN = 15;
        private const int SNI_MAX_ITEM = 4;

        /**
         * The bus names a StatusNotifierItem tray icon can claim.
         *
         * Two tray flavours exist. The object-path one hands the watcher a path on a
         * name the app already owns and so needs no rule of its own. The named one
         * registers org.kde.StatusNotifierItem-<pid>-<n> (libappindicator, Qt) or
         * org.freedesktop.StatusNotifierItem-<pid>-<n> (Chromium, so Electron). Electron
         * 43 drops its tray when that name is refused. The proxy's only wildcard is a
         * trailing ".*", which cannot match a name that varies before the last dot.
         *
         * "--own=org.kde.*" would match, but it would also let the app claim
         * org.kde.StatusNotifierWatcher itself, or a KDE wallet name. Enumerating the
         * handful of names actually reachable is uglier and strictly safer: the pid
         * namespace makes them small and predictable, since bwrap is pid 1 and the app
         * is pid 2. An app sharing the host's pids gets the same span from `app_pid`,
         * its real pid, which the launcher reads from bwrap before starting the proxy.
         */
        private static Gee.ArrayList<string> status_notifier_item_names(int app_pid) {
            var rules = new Gee.ArrayList<string>();
            int first = app_pid > 0 ? app_pid : 2;
            for (int pid = first; pid < first + SNI_PID_SPAN; pid++) {
                for (int item = 1; item <= SNI_MAX_ITEM; item++) {
                    rules.add("--own=org.kde.StatusNotifierItem-%d-%d".printf(pid, item));
                    rules.add("--own=org.freedesktop.StatusNotifierItem-%d-%d".printf(pid, item));
                }
            }
            return rules;
        }

        /**
         * System-bus rules. Spawned for every app unless a store template asks for no
         * system bus, see SandboxManifest.needs_system_bus. NetworkManager has an
         * information-only permission; UPower is not exposed.
         */
        public static Gee.ArrayList<string> system_rules(SandboxManifest manifest) {
            var rules = new Gee.ArrayList<string>();
            add_exact_rules(rules, manifest.system_rules);
            if (manifest.system_bus_access != "none") {
                rules.add_all(logind_rules());
            }
            if (manifest.bluetooth) {
                rules.add("--talk=org.bluez");
            }
            if (manifest.location) {
                rules.add_all(geoclue_rules());
            }
            if (manifest.network_info) {
                rules.add_all(network_info_rules());
            }
            if (manifest.polkit) {
                rules.add_all(polkit_rules());
            }
            return rules;
        }

        /**
         * Polkit, narrowed to a client checking its own authorization. Registering an
         * authentication agent stays refused: an agent is handed the password prompts
         * of whichever process it names.
         */
        public static Gee.ArrayList<string> polkit_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.PolicyKit1";
            const string path = "/org/freedesktop/PolicyKit1/Authority";
            foreach (var member in new string[] { "CheckAuthorization", "CancelCheckAuthorization", "EnumerateActions" }) {
                rules.add("--call=%s=%s.Authority.%s@%s".printf(service, service, member, path));
            }
            foreach (var member in new string[] { "Get", "GetAll" }) {
                rules.add("--call=%s=org.freedesktop.DBus.Properties.%s@%s".printf(service, member, path));
            }
            return rules;
        }

        /**
         * Sleep and shutdown notices from logind. Electron emits its "suspend" event
         * only after PrepareForSleep, and gives up for good when logind is not on the
         * bus, so Bitwarden's "lock on system sleep" never fires without this.
         *
         * Inhibit lets the app take the delay lock that holds suspend until it has
         * locked. The proxy cannot filter arguments, so a "block" lock is possible
         * too; flatpak grants all of logind for the same purpose.
         */
        public static Gee.ArrayList<string> logind_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.login1";
            const string path = "/org/freedesktop/login1";
            rules.add("--call=%s=%s.Manager.Inhibit@%s".printf(service, service, path));
            foreach (var member in new string[] { "PrepareForSleep", "PrepareForShutdown" }) {
                rules.add("--broadcast=%s=%s.Manager.%s@%s".printf(service, service, member, path));
            }
            return rules;
        }

        private static void add_exact_rules(Gee.ArrayList<string> output, string[] rules) {
            foreach (var rule in rules) {
                var colon = rule.index_of_char(':');
                if (colon <= 0) continue;
                var access = rule.substring(0, colon);
                var name = rule.substring(colon + 1);
                if (access in new string[] { "see", "talk", "own" }) output.add("--%s=%s".printf(access, name));
            }
        }

        public static Gee.ArrayList<string> network_info_rules() {
            var rules = new Gee.ArrayList<string>();
            const string service = "org.freedesktop.NetworkManager";
            var root = "/org/freedesktop/NetworkManager";
            // nm.dart initializes from the object manager, not GetDevices alone.
            rules.add("--call=%s=org.freedesktop.DBus.ObjectManager.GetManagedObjects@/org/freedesktop".printf(service));
            foreach (var member in new string[] { "InterfacesAdded", "InterfacesRemoved" }) {
                rules.add("--broadcast=%s=org.freedesktop.DBus.ObjectManager.%s@/org/freedesktop".printf(service, member));
            }
            foreach (var path in new string[] { root, root + "/*" }) {
                foreach (var member in new string[] { "Get", "GetAll" }) {
                    rules.add("--call=%s=org.freedesktop.DBus.Properties.%s@%s".printf(service, member, path));
                }
                rules.add("--broadcast=%s=org.freedesktop.DBus.Properties.PropertiesChanged@%s".printf(service, path));
            }
            foreach (var member in new string[] { "GetDevices", "GetAllDevices", "GetDeviceByIpIface" }) {
                rules.add("--call=%s=%s.%s@%s".printf(service, service, member, root));
            }
            // No Set, activation, Settings methods, secrets or wireless scans.
            return rules;
        }

        /**
         * GeoClue2, narrowed to the objects a client actually uses: the manager it asks
         * for a client object, and the client object itself, whose path is handed out at
         * runtime as /org/freedesktop/GeoClue2/Client/<n> with the fix hanging below it.
         * The trailing "/*" is a subtree match, so one rule covers a client and its
         * Location children.
         *
         * Deliberately not a bare --talk=org.freedesktop.GeoClue2: a rule with no path
         * or interface permits the whole service. --call already implies talk, which is
         * what lets the D-Bus-activated daemon start on the first call.
         *
         * LocationUpdated needs no rule of its own - geoclue emits it addressed to the
         * client rather than broadcast, and the proxy only filters signals with no
         * destination. PropertiesChanged is a real broadcast and does need one, or an
         * app relying on property caching never sees the fix arrive.
         */
        private static Gee.ArrayList<string> geoclue_rules() {
            var rules = new Gee.ArrayList<string>();
            foreach (var rule in new string[] {
                "--call=org.freedesktop.GeoClue2=org.freedesktop.GeoClue2.Manager.*@/org/freedesktop/GeoClue2/Manager",
                "--call=org.freedesktop.GeoClue2=org.freedesktop.DBus.Properties.*@/org/freedesktop/GeoClue2/Manager",
                "--call=org.freedesktop.GeoClue2=org.freedesktop.GeoClue2.Client.*@/org/freedesktop/GeoClue2/Client/*",
                "--call=org.freedesktop.GeoClue2=org.freedesktop.DBus.Properties.*@/org/freedesktop/GeoClue2/Client/*",
                "--broadcast=org.freedesktop.GeoClue2=org.freedesktop.DBus.Properties.PropertiesChanged@/org/freedesktop/GeoClue2/*"
            }) {
                rules.add(rule);
            }
            return rules;
        }

        /**
         * Accessibility-bus rules, taken from flatpak's own a11y proxy: enough for a
         * toolkit to publish its accessible tree and to hear which events something is
         * listening for, and nothing else.
         *
         * The a11y bus needs filtering as much as the session bus does. It is how a
         * screen reader reads every window on the desktop, so an app with a free run of
         * it can read other apps' contents and watch their keystrokes - which is why the
         * app is not simply handed the real socket.
         */
        private static Gee.ArrayList<string> a11y_rules() {
            var rules = new Gee.ArrayList<string>();
            foreach (var rule in new string[] {
                "--broadcast=org.a11y.atspi.Registry=org.a11y.atspi.Registry.EventListenerRegistered@/org/a11y/atspi/registry",
                "--broadcast=org.a11y.atspi.Registry=org.a11y.atspi.Registry.EventListenerDeregistered@/org/a11y/atspi/registry",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Embed@/org/a11y/atspi/accessible/root",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.Socket.Unembed@/org/a11y/atspi/accessible/root",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.Registry.GetRegisteredEvents@/org/a11y/atspi/registry",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetKeystrokeListeners@/org/a11y/atspi/registry/deviceeventcontroller",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.GetDeviceEventListeners@/org/a11y/atspi/registry/deviceeventcontroller",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersSync@/org/a11y/atspi/registry/deviceeventcontroller",
                "--call=org.a11y.atspi.Registry=org.a11y.atspi.DeviceEventController.NotifyListenersAsync@/org/a11y/atspi/registry/deviceeventcontroller"
            }) {
                rules.add(rule);
            }
            return rules;
        }

        /**
         * The accessibility bus's address. It is a bus of its own, not a service on the
         * session bus, so it has an address of its own: whatever the session already put
         * in the environment, or else the answer to org.a11y.Bus.GetAddress, which
         * starts at-spi-bus-launcher on the way if it is not running yet.
         *
         * Null when the session has no accessibility bus at all. That is not an error -
         * the app then starts without one, which is what happens outside a sandbox too.
         */
        public static string? a11y_bus_address() {
            var env = Environment.get_variable("AT_SPI_BUS_ADDRESS");
            if (env != null && env.strip() != "") {
                return env.strip();
            }
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                var reply = bus.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus",
                                          "GetAddress", null, new VariantType("(s)"),
                                          DBusCallFlags.NONE, 5000);
                string address;
                reply.get("(s)", out address);
                return (address != null && address.strip() != "") ? address.strip() : null;
            } catch (Error e) {
                debug("Sandbox: no accessibility bus: %s", e.message);
                return null;
            }
        }

        /**
         * The real accessibility bus socket, for the full-session-bus case where no
         * proxy runs and there is nothing to filter with.
         */
        public static string? host_a11y_socket() {
            var address = a11y_bus_address();
            return address == null ? null : SandboxBwrap.socket_path_in(address);
        }

        /**
         * The address of the session bus to proxy. Uses DBUS_SESSION_BUS_ADDRESS as
         * given - it is an address, not a path, so abstract sockets work here even
         * though they could not be bind-mounted into the sandbox.
         */
        private static string? host_session_bus_address() {
            var address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
            if (address != null && address.strip() != "") {
                return address.strip();
            }
            var fallback = Path.build_filename(AppPaths.sandbox_runtime_base, "bus");
            if (GLib.FileUtils.test(fallback, FileTest.EXISTS)) {
                return "unix:path=%s".printf(fallback);
            }
            return null;
        }

        /**
         * The proxy's --args format: every argument followed by a NUL byte. Built as
         * bytes rather than a string, which would end at the first separator.
         */
        private static uint8[] nul_separated(Gee.List<string> items) {
            int total = 0;
            foreach (var item in items) {
                total += item.data.length + 1;
            }
            var result = new uint8[total];
            int offset = 0;
            foreach (var item in items) {
                foreach (var byte in item.data) {
                    result[offset++] = byte;
                }
                result[offset++] = 0;
            }
            return result;
        }

        public static void set_cloexec(int fd) {
            int flags = Posix.fcntl(fd, Posix.F_GETFD);
            if (flags >= 0) {
                Posix.fcntl(fd, Posix.F_SETFD, flags | Posix.FD_CLOEXEC);
            }
        }

        private static void clear_cloexec(int fd) {
            int flags = Posix.fcntl(fd, Posix.F_GETFD);
            if (flags >= 0) {
                Posix.fcntl(fd, Posix.F_SETFD, flags & ~Posix.FD_CLOEXEC);
            }
        }

        private static void unlink_if_present(string? path) {
            if (path != null && GLib.FileUtils.test(path, FileTest.EXISTS)) {
                GLib.FileUtils.unlink(path);
            }
        }
    }
}
