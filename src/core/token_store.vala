namespace AppManager.Core {

    /**
     * Stores the update and AppHub GitHub tokens independently, as securely as the running
     * system allows, using two tiers tried in order:
     *
     *   Tier 1 - the freedesktop Secret Service (GNOME Keyring, KWallet,
     *            KeePassXC) via libsecret. Encrypted at rest, unlocked with
     *            the login session. This is the platform-correct location.
     *
     *   Tier 2 - a machine+user-bound AES-256-GCM blob kept in GSettings,
     *            used only when no Secret Service is on the bus. This is
     *            obfuscation, not strong crypto (see crypto_shim.h): it makes
     *            a synced or exfiltrated config file useless off its origin
     *            machine, nothing more.
     *
     * Each token has its own keyring schema and encrypted GSettings key. For
     * each purpose, a successful write to one tier clears the other. Clearing
     * or migrating the update token never touches the AppHub credential.
     *
     * Request getters enforce the enable switches before reading credentials.
     * Only update requests may use the GITHUB_TOKEN / GH_TOKEN environment fallback.
     *
     * All methods are synchronous. Keyring writes may raise an unlock prompt,
     * so set_token()/clear_token() run only from the preferences UI.
     * get_token() never prompts: a locked or absent keyring simply yields
     * null and the caller degrades to tier 2, then env, then unauthenticated
     * requests - the intended behaviour for the headless background service.
     */
    public class TokenStore : Object {
        private const string LEGACY_KEY = "github-token";
        private const string CIPHER_KEY = "github-token-cipher";
        private const string SCHEMA_NAME = "com.github.AppManager.GitHubToken";
        private const string KEYRING_LABEL = "AppManager GitHub token";
        private const string APPHUB_CIPHER_KEY = "apphub-token-cipher";
        private const string APPHUB_SCHEMA_NAME = "com.github.AppManager.AppHubToken";
        private const string APPHUB_KEYRING_LABEL = "AppManager AppHub submission token";
        private const string APP_ATTR = "app-manager";

        private static Secret.Schema build_schema(bool apphub = false) {
            return new Secret.Schema(apphub ? APPHUB_SCHEMA_NAME : SCHEMA_NAME, Secret.SchemaFlags.NONE,
                "application", Secret.SchemaAttributeType.STRING);
        }

        private static GitHubAuth authentication(bool apphub) {
            return apphub ? GitHubAuth.get_apphub() : GitHubAuth.get_updates();
        }

        /**
         * Returns the stored token, or null when none is set anywhere.
         * Order: keyring → tier-2 blob. Migrates the legacy key first.
         */
        public static string? get_token() {
            migrate_legacy();
            return get_stored_token(false);
        }

        /** AppHub is explicitly configured: never fall back to the update token or env. */
        public static string? get_apphub_token() {
            return get_stored_token(true);
        }

        public static bool updates_enabled() {
            return new GLib.Settings(APPLICATION_ID).get_boolean("github-token-enabled");
        }

        public static bool apphub_enabled() {
            return new GLib.Settings(APPLICATION_ID).get_boolean("apphub-token-enabled");
        }

        /** Disabled means no stored token, legacy migration, or environment fallback. */
        public static string? get_update_request_token() {
            if (!updates_enabled()) return null;
            var stored = get_token();
            if (stored != null) return stored;
            foreach (var key in new string[] { "GITHUB_TOKEN", "GH_TOKEN" }) {
                var value = Environment.get_variable(key);
                if (value != null && value.strip() != "") return value.strip();
            }
            return null;
        }

        public static string? get_apphub_request_token() {
            return apphub_enabled() ? get_apphub_token() : null;
        }

        private static string? get_stored_token(bool apphub) {
            try {
                var schema = build_schema(apphub);
                string? found = Secret.password_lookup_sync(schema, null, "application", APP_ATTR);
                if (found != null && found.strip() != "") {
                    return found.strip();
                }
            } catch (GLib.Error e) {
                // Secret Service unavailable or locked: fall through to tier 2.
            }

            var settings = new GLib.Settings(APPLICATION_ID);
            var blob = settings.get_string(apphub ? APPHUB_CIPHER_KEY : CIPHER_KEY);
            if (blob != null && blob.strip() != "") {
                var plain = AppManager.Crypto.decrypt(blob);
                if (plain != null && plain.strip() != "") {
                    return plain.strip();
                }
            }

            return null;
        }

        /**
         * Stores the token in the keyring, falling back to the tier-2 blob.
         * An empty token clears everything. Returns false only if both tiers
         * fail (no Secret Service and no machine-id for tier 2).
         */
        public static bool set_token(string token) {
            return set_stored_token(token, false);
        }

        public static bool set_apphub_token(string token) {
            return set_stored_token(token, true);
        }

        private static bool set_stored_token(string token, bool apphub) {
            var trimmed = token.strip();
            if (trimmed == "") {
                clear_stored_token(apphub);
                return true;
            }

            var settings = new GLib.Settings(APPLICATION_ID);

            try {
                var schema = build_schema(apphub);
                bool ok = Secret.password_store_sync(schema, Secret.COLLECTION_DEFAULT,
                    apphub ? APPHUB_KEYRING_LABEL : KEYRING_LABEL, trimmed, null, "application", APP_ATTR);
                if (ok) {
                    // Keep exactly one copy: drop the tier-2 blob and legacy key.
                    reset_if_set(settings, apphub ? APPHUB_CIPHER_KEY : CIPHER_KEY);
                    if (!apphub) reset_if_set(settings, LEGACY_KEY);
                    authentication(apphub).invalidate();
                    return true;
                }
            } catch (GLib.Error e) {
                // Fall through to tier 2.
            }

            var blob = AppManager.Crypto.encrypt(trimmed);
            if (blob != null) {
                if (!settings.set_string(apphub ? APPHUB_CIPHER_KEY : CIPHER_KEY, blob)) return false;
                // Keep exactly one copy: drop any keyring entry and legacy key.
                clear_keyring(apphub);
                if (!apphub) reset_if_set(settings, LEGACY_KEY);
                authentication(apphub).invalidate();
                return true;
            }

            return false;
        }

        /** Clears the token from both tiers and the legacy plaintext key. */
        public static void clear_token() {
            clear_stored_token(false);
        }

        public static void clear_apphub_token() {
            clear_stored_token(true);
        }

        private static void clear_stored_token(bool apphub) {
            clear_keyring(apphub);
            var settings = new GLib.Settings(APPLICATION_ID);
            reset_if_set(settings, apphub ? APPHUB_CIPHER_KEY : CIPHER_KEY);
            if (!apphub) reset_if_set(settings, LEGACY_KEY);
            authentication(apphub).invalidate();
        }

        private static void reset_if_set(GLib.Settings settings, string key) {
            if (settings.get_string(key) != "") {
                settings.reset(key);
            }
        }

        private static void clear_keyring(bool apphub) {
            try {
                var schema = build_schema(apphub);
                Secret.password_clear_sync(schema, null, "application", APP_ATTR);
            } catch (GLib.Error e) {
                // No Secret Service, or nothing stored: nothing to do.
            }
        }

        /**
         * One-time lazy migration: if the legacy plaintext key still holds a
         * token, move it into a tier and reset the legacy key. Lazy migration
         * covers both the GUI and the --background-update entry points with a
         * single code path. Note: it cannot scrub old config backups - users
         * who care should revoke and re-issue the token.
         */
        private static void migrate_legacy() {
            var settings = new GLib.Settings(APPLICATION_ID);
            var legacy = settings.get_string(LEGACY_KEY);
            if (legacy != null && legacy.strip() != "") {
                if (set_token(legacy.strip())) {
                    reset_if_set(settings, LEGACY_KEY);
                }
            }
        }
    }
}
