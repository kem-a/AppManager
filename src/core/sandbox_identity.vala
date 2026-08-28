namespace AppManager.Core {
    /**
     * The identity a sandboxed app presents on D-Bus.
     *
     * Two names matter and they are not the same thing:
     *
     *  - The **app id** (io.appmanager.sandboxed.<Slug>) is ours. It is what the
     *    compositor's Wayland security context tags the app's connection with, so it
     *    must be stable for the life of the installation - a changing id makes the
     *    compositor see a different client after every upgrade, and any per-app policy
     *    keyed on it stops applying. It is generated once, stored on the record, and
     *    carried across upgrades.
     *
     *  - The **own names** are the app's own: the bus names it would claim if it were
     *    not sandboxed. They have to be allowed through the proxy or the app cannot
     *    register itself at all - a GApplication whose name request is denied concludes
     *    it is not the primary instance and exits.
     */
    public class SandboxIdentity {
        /**
         * Assigns record.sandbox_app_id if it does not have one yet.
         *
         * `existing` is used only to avoid handing two records the same id, which
         * would make two apps present the compositor the same identity. Pass the whole
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
                // be rejected by the compositor's security context, so never store one.
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
         * The flatpak application-id rules, kept as the shape of a well-formed app id:
         * at least three dot-separated elements, each non-empty and
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
         * entry's file name - which is what a GApplication uses as its application id
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
}
