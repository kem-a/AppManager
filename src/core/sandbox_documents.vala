namespace AppManager.Core {
    /**
     * A folder the document portal has granted an app, which the permission screen
     * does not otherwise know about.
     */
    public class SandboxFolderGrant : Object {
        public string doc_id { get; set; default = ""; }
        public string path { get; set; default = ""; }
    }

    /**
     * Reads and withdraws the document portal's own grants, so the permission screen
     * can show what an app actually has.
     *
     * The portal issues a grant every time the user picks something in a file dialog,
     * and those grants are deliberately independent of the folder toggles. That is what
     * makes portals worth having: an app with no Pictures permission can still open the
     * one picture the user chose, and nothing else.
     *
     * What the portal never does is take them back, or tell anyone they exist. A single
     * picked file is narrow enough not to matter. A picked *folder* is not: an app's
     * "choose your library folder" preference hands over everything in it, to read and
     * to write, for good — so a folder switched off in the sandbox settings goes on
     * being readable and writable across restarts, with nothing on screen saying so.
     *
     * Rather than fight that, the folder grants are surfaced: folder_grants() reports
     * the ones the settings do not already cover, the permission screen lists them
     * alongside the folders the user added by hand, and revoke() withdraws one when the
     * user removes it. Nothing is taken away behind the user's back; the screen simply
     * stops disagreeing with reality.
     */
    public class SandboxDocuments {
        // Every permission the document portal tracks. Revoking all four drops the app
        // from the document's grant list entirely; revoking a subset would leave it
        // holding the rest.
        private const string[] ALL_PERMISSIONS = { "read", "write", "grant-permissions", "delete" };

        private const string BUS_NAME = "org.freedesktop.portal.Documents";
        private const string OBJECT_PATH = "/org/freedesktop/portal/documents";

        // Short on purpose: this runs while the user is waiting for the permission
        // screen to appear, and a portal that is not answering must not hold it up.
        private const int TIMEOUT_MS = 3000;

        /**
         * The folders the portal has granted this app that its own settings do not
         * already allow — the ones that would otherwise be invisible.
         *
         * Single files are left out. The user picked one specific file in a dialog,
         * which is a decision about that file and nothing more; listing every recently
         * opened document as a permission would bury the folders that matter.
         *
         * Returns empty when the app has no portal identity, when portals are off for
         * it, or when the document portal is not answering — in every one of those
         * cases there is nothing the screen could usefully show.
         */
        public static Gee.ArrayList<SandboxFolderGrant> folder_grants(SandboxManifest manifest) {
            var found = new Gee.ArrayList<SandboxFolderGrant>();
            var app_id = manifest.app_id.strip();
            if (app_id == "" || !manifest.portals) {
                return found;
            }
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                var reply = bus.call_sync(BUS_NAME, OBJECT_PATH, BUS_NAME, "List",
                                          new Variant.tuple({ new Variant.string(app_id) }),
                                          new VariantType("(a{say})"),
                                          DBusCallFlags.NONE, TIMEOUT_MS);
                var roots = allowed_roots(manifest);
                var docs = reply.get_child_value(0);
                for (size_t i = 0; i < docs.n_children(); i++) {
                    var entry = docs.get_child_value(i);
                    // The path is a byte string, not UTF-8: a file name is bytes on
                    // Linux and need not decode.
                    var path = entry.get_child_value(1).get_bytestring();
                    if (path == "" || covered(path, roots)) {
                        continue;
                    }
                    if (!GLib.FileUtils.test(path, FileTest.IS_DIR)) {
                        continue;
                    }
                    var grant = new SandboxFolderGrant();
                    grant.doc_id = entry.get_child_value(0).get_string();
                    grant.path = path;
                    found.add(grant);
                }
            } catch (Error e) {
                debug("Sandbox: cannot read document grants for %s: %s", app_id, e.message);
            }
            return found;
        }

        /**
         * Withdraws one grant. Returns false when the portal refused or was not there,
         * so the caller can leave the row in place rather than claim an access was
         * removed that in fact still stands.
         */
        public static bool revoke(string app_id, string doc_id) {
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                bus.call_sync(BUS_NAME, OBJECT_PATH, BUS_NAME, "RevokePermissions",
                              new Variant.tuple({
                                  new Variant.string(doc_id),
                                  new Variant.string(app_id),
                                  new Variant.strv(ALL_PERMISSIONS)
                              }),
                              null, DBusCallFlags.NONE, TIMEOUT_MS);
                message("Sandbox: revoked %s's document grant %s", app_id, doc_id);
                return true;
            } catch (Error e) {
                warning("Sandbox: cannot revoke document grant %s for %s: %s",
                        doc_id, app_id, e.message);
                return false;
            }
        }

        /**
         * The folders the app may reach without any grant at all: the private home, the
         * XDG directories that are toggled on, and the hand-picked extra folders.
         */
        private static Gee.ArrayList<string> allowed_roots(SandboxManifest manifest) {
            var roots = new Gee.ArrayList<string>();
            // The app's own home. A grant on something in there tells the user nothing
            // they cannot already see in the settings.
            if (manifest.home.strip() != "") {
                roots.add(SandboxConfig.canonicalize(manifest.home.strip()));
            }
            foreach (var name in manifest.xdg_dirs) {
                string requested;
                var dir = SandboxBwrap.xdg_dir_path(name.strip(), out requested);
                if (dir != null) {
                    roots.add(dir);
                }
            }
            foreach (var entry in manifest.extra_dirs) {
                var trimmed = entry.strip();
                if (trimmed == "") {
                    continue;
                }
                // Read-only and read-write folders are both already on screen; the
                // suffix only says how, and a grant adds nothing to either.
                if (trimmed.has_suffix(":rw")) {
                    trimmed = trimmed.substring(0, trimmed.length - 3);
                }
                roots.add(SandboxConfig.canonicalize(trimmed));
            }
            return roots;
        }

        /**
         * Whether `path` sits in one of `roots`. Compared after resolving symlinks, and
         * only on a separator boundary — otherwise "/home/a/Pictures2" would count as
         * being inside "/home/a/Pictures".
         */
        private static bool covered(string path, Gee.Collection<string> roots) {
            var real = SandboxConfig.canonicalize(path);
            foreach (var root in roots) {
                if (real == root || real.has_prefix(root + Path.DIR_SEPARATOR_S)) {
                    return true;
                }
            }
            return false;
        }
    }
}
