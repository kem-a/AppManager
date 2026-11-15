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
         * entry's file name and matched bundled AppStream metadata. GApplication
         * conventionally uses these as the identity it will try to claim.
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
                basename = strip_copy_suffix(basename, record.copy_index);
                if (is_ownable_bus_name(basename)) {
                    names.add(basename);
                }
            }
            var appstream_id = (record.appstream_id ?? "").strip();
            if (appstream_id.has_suffix(".desktop")) {
                appstream_id = appstream_id.substring(0, appstream_id.length - ".desktop".length);
            }
            if (is_ownable_bus_name(appstream_id) && !names.contains(appstream_id)) {
                names.add(appstream_id);
            }
            var wm_class = record.original_startup_wm_class ?? "";
            if (is_ownable_bus_name(wm_class) && !names.contains(wm_class)) names.add(wm_class);
            return names.to_array();
        }

        public static string[] media_names_for(InstallationRecord record) {
            var names = new Gee.ArrayList<string>();
            foreach (var declared in record.sandbox_media_names ?? new string[0]) {
                if (AppHubPolicy.valid_media_name(declared) && !names.contains(declared)) names.add(declared);
            }
            // Players commonly publish under a name derived from the application ID
            // (Gapless: org.mpris.MediaPlayer2.com.github.neithern.g4music), which a
            // declared display-name entry alone would not cover. Grant both.
            foreach (var identity in own_names_for(record)) {
                var name = "org.mpris.MediaPlayer2." + identity;
                if (AppHubPolicy.valid_media_name(name) && !names.contains(name)) names.add(name);
                var leaf = identity.substring(identity.last_index_of_char('.') + 1);
                name = "org.mpris.MediaPlayer2." + leaf;
                if (AppHubPolicy.valid_media_name(name) && !names.contains(name)) names.add(name);
            }
            // Display names are a common player suffix (Gapless), independent of
            // the application ID (g4music). Secondary copies use the same suffix.
            var title = record.original_name ?? record.name;
            if (record.copy_index >= 2 && title.has_suffix(" %d".printf(record.copy_index))) {
                title = title.substring(0, title.length - " %d".printf(record.copy_index).length);
            }
            var suffix = new StringBuilder();
            foreach (var c in title.to_utf8()) {
                if (c.isalnum() || c == '_' || c == '-') suffix.append_c(c);
            }
            var candidate = "org.mpris.MediaPlayer2." + suffix.str;
            if (AppHubPolicy.valid_media_name(candidate) && !names.contains(candidate)) names.add(candidate);
            return names.to_array();
        }

        // A side-by-side copy's desktop file is "<name>-N", or "<name>-N-i" when
        // unique_path() had to step aside, but the app inside still claims <name>.
        private static string strip_copy_suffix(string stem, int copy_index) {
            if (copy_index < 2) {
                return stem;
            }
            var marker = "-%d".printf(copy_index);
            var result = stem;
            var dash = result.last_index_of_char('-');
            if (!result.has_suffix(marker) && dash > 0 && result.substring(0, dash).has_suffix(marker)) {
                var tail = result.substring(dash + 1);
                bool digits = tail.length > 0;
                for (int i = 0; i < tail.length && digits; i++) {
                    digits = tail[i].isdigit();
                }
                if (digits) {
                    result = result.substring(0, dash);
                }
            }
            if (result.has_suffix(marker)) {
                result = result.substring(0, result.length - marker.length);
            }
            return result;
        }

        // Names no app gets to claim through us, whatever its desktop entry is called.
        // Owning one of these on the real session bus would let a sandboxed app
        // impersonate the service and read what other apps send it. And in
        // xdg-dbus-proxy an own rule also lets the app call the name and everything
        // below it, so a name the AppImage picked for itself must not cover a host
        // service that runs commands, changes settings or reads files for its callers.
        private const string[] RESERVED_NAME_PREFIXES = {
            "org.freedesktop.DBus",
            "org.freedesktop.portal",
            "org.freedesktop.impl.portal",
            "org.freedesktop.Notifications",
            "org.freedesktop.secrets",
            "org.freedesktop.systemd1",
            "org.freedesktop.Flatpak",
            "org.kde.StatusNotifierWatcher",
            "org.a11y.",
            "org.gnome.Shell",
            "org.gnome.Mutter",
            "org.gnome.SessionManager",
            "org.gnome.SettingsDaemon",
            "org.gnome.Terminal",
            "org.gnome.keyring",
            "org.gnome.OnlineAccounts",
            "org.gnome.evolution.dataserver",
            "org.gtk.vfs",
            "org.kde.KWin",
            "org.kde.plasmashell",
            "org.kde.krunner",
            "org.kde.konsole",
            "org.kde.kded",
            "org.kde.klauncher",
            "org.kde.kwalletd",
            "ca.desrt.dconf"
        };

        /**
         * Whether `name` is a well-known bus name an app may be allowed to own: valid
         * D-Bus syntax, at least three elements (flatpak's rule for app ids, so the
         * "name.*" grant never spans a whole vendor namespace), and neither one of
         * the reserved services nor a parent namespace of one.
         */
        public static bool is_ownable_bus_name(string name) {
            if (name.length == 0 || name.length > 255 || name.has_prefix(".") || name.has_suffix(".")) {
                return false;
            }
            var elements = name.split(".");
            if (elements.length < 3) {
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
                // Both ways: "name.*" is granted too, so a parent of a reserved name
                // would cover it just the same.
                if (name == reserved || name.has_prefix(reserved) || reserved.has_prefix(name + ".")) {
                    return false;
                }
            }
            return true;
        }
    }
}
