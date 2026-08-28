namespace AppManager.Core {
    /**
     * The identity a sandboxed app presents on D-Bus.
     *
     * Two names matter and they are not the same thing:
     *
     *  - The **app id** (io.appmanager.sandboxed.<Slug>) is ours. It is what
     *    xdg-desktop-portal records permissions against and what the document portal
     *    keys grants by, so it must be stable for the life of the installation — it is
     *    generated once, stored on the record, and carried across upgrades.
     *
     *  - The **own names** are the app's own: the bus names it would claim if it were
     *    not sandboxed. They have to be allowed through the proxy or the app cannot
     *    register itself at all — a GApplication whose name request is denied concludes
     *    it is not the primary instance and exits.
     */
    public class SandboxIdentity {
        /**
         * Assigns record.sandbox_app_id if it does not have one yet.
         *
         * `existing` is used only to avoid handing two records the same id, which
         * would make them share portal permissions and document grants. Pass the whole
         * registry where it is available.
         */
        public static void ensure_app_id(InstallationRecord record, InstallationRecord[]? existing = null) {
            if (record.sandbox_app_id != null && record.sandbox_app_id.strip() != "") {
                return;
            }

            var taken = new Gee.HashSet<string>();
            foreach (var other in existing ?? new InstallationRecord[0]) {
                if (other.id != record.id && other.sandbox_app_id != null) {
                    taken.add(other.sandbox_app_id);
                }
            }

            var base_id = "%s.%s".printf(SANDBOX_APP_ID_PREFIX, slug_for(record.name));
            var candidate = base_id;
            for (int n = 2; taken.contains(candidate); n++) {
                candidate = "%s_%d".printf(base_id, n);
            }

            if (!is_valid_app_id(candidate)) {
                // Cannot happen with a slug built by slug_for, but an invalid id would
                // make every portal call fail rather than degrade, so never store one.
                warning("Sandbox: generated app id \"%s\" is not valid, falling back", candidate);
                candidate = "%s.app".printf(SANDBOX_APP_ID_PREFIX);
            }
            record.sandbox_app_id = candidate;
            debug("Sandbox: assigned app id %s to %s", candidate, record.name);
        }

        /**
         * The last element of an app id, derived from the app's display name: everything
         * outside [A-Za-z0-9_] becomes "_", and a leading digit is prefixed, because an
         * app-id element may not start with one.
         */
        public static string slug_for(string name) {
            var builder = new StringBuilder();
            foreach (var c in name.to_utf8()) {
                bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_';
                builder.append_c(plain ? (char) c : '_');
            }
            var slug = builder.str;
            if (slug == "") {
                return "app";
            }
            if (slug[0] >= '0' && slug[0] <= '9') {
                return "a%s".printf(slug);
            }
            return slug;
        }

        /**
         * The flatpak application-id rules, which xdg-desktop-portal reimplements and
         * validates against: at least three dot-separated elements, each non-empty and
         * made of [A-Za-z0-9_-], none starting with a digit, "-" only in the last
         * element, no leading dot, at most 255 bytes.
         */
        public static bool is_valid_app_id(string id) {
            if (id.length == 0 || id.length > 255 || id.has_prefix(".")) {
                return false;
            }
            var elements = id.split(".");
            if (elements.length < 3) {
                return false;
            }
            for (int i = 0; i < elements.length; i++) {
                var element = elements[i];
                if (element.length == 0) {
                    return false;
                }
                if (element[0] >= '0' && element[0] <= '9') {
                    return false;
                }
                bool last = (i == elements.length - 1);
                for (int j = 0; j < element.length; j++) {
                    var c = element[j];
                    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                        || (c >= '0' && c <= '9') || c == '_' || (c == '-' && last);
                    if (!ok) {
                        return false;
                    }
                }
            }
            return true;
        }

        /**
         * The bus names a record's app should be allowed to own, taken from its desktop
         * entry's file name — which is what a GApplication uses as its application id
         * by convention, and therefore the name it will try to claim.
         *
         * Returns an empty list when nothing name-like can be derived, in which case
         * the app simply gets no --own rule.
         */
        public static string[] own_names_for(InstallationRecord record) {
            var names = new Gee.ArrayList<string>();
            if (record.desktop_file != null && record.desktop_file.strip() != "") {
                var basename = Path.get_basename(record.desktop_file.strip());
                if (basename.has_suffix(".desktop")) {
                    basename = basename.substring(0, basename.length - ".desktop".length);
                }
                if (is_ownable_bus_name(basename)) {
                    names.add(basename);
                }
            }
            return names.to_array();
        }

        // Names no app gets to claim through us, whatever its desktop entry is called.
        // Owning one of these on the real session bus would let a sandboxed app
        // impersonate the service and read what other apps send it.
        private const string[] RESERVED_NAME_PREFIXES = {
            "org.freedesktop.DBus",
            "org.freedesktop.portal",
            "org.freedesktop.impl.portal",
            "org.freedesktop.Notifications",
            "org.freedesktop.secrets",
            "org.freedesktop.systemd1",
            "org.kde.StatusNotifierWatcher",
            "org.a11y."
        };

        /**
         * Whether `name` is a well-known bus name an app may be allowed to own: valid
         * D-Bus syntax, at least two elements, and not one of the desktop services.
         */
        public static bool is_ownable_bus_name(string name) {
            if (name.length == 0 || name.length > 255 || name.has_prefix(".") || name.has_suffix(".")) {
                return false;
            }
            var elements = name.split(".");
            if (elements.length < 2) {
                return false;
            }
            foreach (var element in elements) {
                if (element.length == 0 || (element[0] >= '0' && element[0] <= '9')) {
                    return false;
                }
                for (int j = 0; j < element.length; j++) {
                    var c = element[j];
                    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                        || (c >= '0' && c <= '9') || c == '_' || c == '-';
                    if (!ok) {
                        return false;
                    }
                }
            }
            foreach (var reserved in RESERVED_NAME_PREFIXES) {
                if (name == reserved || name.has_prefix(reserved)) {
                    return false;
                }
            }
            return true;
        }
    }

    /**
     * One launch's portal identity: the files xdg-desktop-portal reads to decide who
     * is calling it, and the document-portal view that belongs to this app.
     *
     * The mechanism is flatpak's, and it is exact rather than approximate on purpose.
     * The portal's app-info resolution tries the flatpak engine first, and that engine
     * treats a missing /.flatpak-info as "not a flatpak app" and falls through to
     * treating the caller as a host process — but a /.flatpak-info that exists and does
     * not parse, or names an invalid app id, or has no matching bwrapinfo.json, is an
     * error with no fallback: *every* portal call then fails. A half-hearted fake is
     * worse than none, so anything missing here means running with portals off.
     *
     * What the portal requires:
     *   - /.flatpak-info in the app's mount namespace, with [Application] name= a valid
     *     app id and [Instance] instance-id=
     *   - $XDG_RUNTIME_DIR/.flatpak/<instance-id>/bwrapinfo.json parsing as JSON with an
     *     integer child-pid, which it uses to obtain a pidfd for the caller. bwrap
     *     writes exactly that file given --info-fd.
     */
    public class SandboxInstance {
        public string id { get; private set; default = ""; }
        public string dir { get; private set; default = ""; }
        // Identical content for /.flatpak-info and for the instance's own info file.
        public string app_info { get; private set; default = ""; }
        // Where bwrap writes bwrapinfo.json. Open before the app starts, because the
        // portal needs to read it as soon as the app makes its first call.
        public int info_fd { get; private set; default = -1; }
        // <document mount point>/by-app/<app-id>, or null when the portal is absent.
        public string? document_dir { get; private set; default = null; }

        /**
         * Prepares the instance state for one launch, or returns null when a valid
         * identity cannot be produced — in which case the caller must run without
         * portals rather than with a broken identity.
         */
        public static SandboxInstance? create(SandboxManifest manifest, string instance_id) {
            var app_id = manifest.app_id.strip();
            if (!SandboxIdentity.is_valid_app_id(app_id)) {
                debug("Sandbox: no valid app id, running without portals");
                return null;
            }

            var self = new SandboxInstance();
            self.id = instance_id;
            // The flatpak-owned path, deliberately: it is the only place
            // xdg-desktop-portal looks for bwrapinfo.json. A random instance id is what
            // keeps this from colliding with a real flatpak instance.
            self.dir = Path.build_filename(AppPaths.sandbox_runtime_base, ".flatpak", instance_id);
            if (DirUtils.create_with_parents(self.dir, 0700) != 0) {
                warning("Sandbox: cannot create %s: %s", self.dir, Posix.strerror(Posix.errno));
                return null;
            }

            self.app_info = build_app_info(app_id, instance_id, manifest.network);
            try {
                GLib.FileUtils.set_contents(Path.build_filename(self.dir, "info"), self.app_info);
            } catch (Error e) {
                warning("Sandbox: cannot write %s/info: %s", self.dir, e.message);
                return null;
            }

            var bwrapinfo = Path.build_filename(self.dir, "bwrapinfo.json");
            self.info_fd = Posix.open(bwrapinfo, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_TRUNC, 0600);
            if (self.info_fd < 0) {
                warning("Sandbox: cannot create %s: %s", bwrapinfo, Posix.strerror(Posix.errno));
                return null;
            }

            self.document_dir = resolve_document_dir(app_id);
            return self;
        }

        /**
         * Closes the info descriptor and removes the instance directory. The portal has
         * no use for it once the app is gone.
         */
        public void cleanup() {
            if (info_fd >= 0) {
                Posix.close(info_fd);
                info_fd = -1;
            }
            if (dir == "") {
                return;
            }
            foreach (var name in new string[] { "info", "bwrapinfo.json" }) {
                GLib.FileUtils.unlink(Path.build_filename(dir, name));
            }
            DirUtils.remove(dir);
        }

        /**
         * The app-info key file. Deliberately minimal: app-path and runtime-path are
         * left out, because their presence turns on the portal's path remapping, and
         * paths need no remapping here — the sandbox binds host directories at their
         * own paths, so a path means the same thing on both sides.
         */
        private static string build_app_info(string app_id, string instance_id, bool network) {
            var kf = new KeyFile();
            kf.set_string("Application", "name", app_id);
            kf.set_string("Instance", "instance-id", instance_id);
            if (network) {
                // Sets the portal's HAS_NETWORK flag. Written as a list, which is the
                // form flatpak uses.
                kf.set_string_list("Context", "shared", { "network" });
            }
            return kf.to_data();
        }

        /**
         * Asks the document portal where it is mounted and returns this app's view of
         * it. Returns null when the portal is not running, in which case file access
         * falls back to the folders granted statically.
         *
         * The by-app/<app-id> directory does not have to exist yet: the portal's FUSE
         * filesystem materializes it on lookup, so binding it works on the very first
         * launch, before the app has been granted anything.
         */
        private static string? resolve_document_dir(string app_id) {
            try {
                var bus = Bus.get_sync(BusType.SESSION, null);
                var reply = bus.call_sync(
                    "org.freedesktop.portal.Documents",
                    "/org/freedesktop/portal/documents",
                    "org.freedesktop.portal.Documents",
                    "GetMountPoint",
                    null,
                    new VariantType("(ay)"),
                    DBusCallFlags.NONE,
                    30000,
                    null);
                var mount_point = reply.get_child_value(0).get_bytestring();
                if (mount_point == null || mount_point.strip() == "") {
                    return null;
                }
                return Path.build_filename(mount_point, "by-app", app_id);
            } catch (Error e) {
                debug("Sandbox: no document portal (%s); static folder grants only", e.message);
                return null;
            }
        }

        /**
         * Whether the desktop portal is reachable at all. Probed rather than
         * version-checked: what matters is whether a call would be answered.
         */
        public static bool portals_available() {
            try {
                var bus = Bus.get_sync(BusType.SESSION, null);
                var reply = bus.call_sync(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "NameHasOwner",
                    new Variant("(s)", "org.freedesktop.portal.Desktop"),
                    new VariantType("(b)"),
                    DBusCallFlags.NONE,
                    5000,
                    null);
                if (reply.get_child_value(0).get_boolean()) {
                    return true;
                }
                // Not running yet is normal — the portal is D-Bus activated.
                var activatable = bus.call_sync(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListActivatableNames",
                    null,
                    new VariantType("(as)"),
                    DBusCallFlags.NONE,
                    5000,
                    null);
                foreach (var name in activatable.get_child_value(0).dup_strv()) {
                    if (name == "org.freedesktop.portal.Desktop") {
                        return true;
                    }
                }
            } catch (Error e) {
                debug("Sandbox: cannot probe for portals: %s", e.message);
            }
            return false;
        }
    }
}
