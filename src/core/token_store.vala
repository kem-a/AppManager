namespace AppManager.Core {

    /**
     * Stores the GitHub personal access token as securely as the running
     * system allows, using two tiers tried in order:
     *
     *   Tier 1 — the freedesktop Secret Service (GNOME Keyring, KWallet,
     *            KeePassXC) via libsecret. Encrypted at rest, unlocked with
     *            the login session. This is the platform-correct location.
     *
     *   Tier 2 — a machine+user-bound AES-256-GCM blob kept in GSettings,
     *            used only when no Secret Service is on the bus. This is
     *            obfuscation, not strong crypto (see crypto_shim.h): it makes
     *            a synced or exfiltrated config file useless off its origin
     *            machine, nothing more.
     *
     * Exactly one tier ever holds a copy: a successful write to one tier
     * clears the other, and clear_token() wipes both plus the legacy key.
     *
     * The GITHUB_TOKEN / GH_TOKEN environment fallback is handled by the
     * caller (Updater), not here.
     *
     * All methods are synchronous. Keyring writes may raise an unlock prompt,
     * so set_token()/clear_token() run only from the preferences UI.
     * get_token() never prompts: a locked or absent keyring simply yields
     * null and the caller degrades to tier 2, then env, then unauthenticated
     * requests — the intended behaviour for the headless background service.
     */
    public class TokenStore : Object {
        private const string LEGACY_KEY = "github-token";
        private const string CIPHER_KEY = "github-token-cipher";
        private const string SCHEMA_NAME = "com.github.AppManager.GitHubToken";
        private const string KEYRING_LABEL = "AppManager GitHub token";
        private const string APP_ATTR = "app-manager";

        private static Secret.Schema build_schema() {
            return new Secret.Schema(SCHEMA_NAME, Secret.SchemaFlags.NONE,
                "application", Secret.SchemaAttributeType.STRING);
        }

        /**
         * Returns the stored token, or null when none is set anywhere.
         * Order: keyring → tier-2 blob. Migrates the legacy key first.
         */
        public static string? get_token() {
            migrate_legacy();

            try {
                var schema = build_schema();
                string? found = Secret.password_lookup_sync(schema, null, "application", APP_ATTR);
                if (found != null && found.strip() != "") {
                    return found.strip();
                }
            } catch (GLib.Error e) {
                // Secret Service unavailable or locked: fall through to tier 2.
            }

            var settings = new GLib.Settings(APPLICATION_ID);
            var blob = settings.get_string(CIPHER_KEY);
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
            var trimmed = token.strip();
            if (trimmed == "") {
                clear_token();
                return true;
            }

            var settings = new GLib.Settings(APPLICATION_ID);

            try {
                var schema = build_schema();
                bool ok = Secret.password_store_sync(schema, Secret.COLLECTION_DEFAULT,
                    KEYRING_LABEL, trimmed, null, "application", APP_ATTR);
                if (ok) {
                    // Keep exactly one copy: drop the tier-2 blob and legacy key.
                    reset_if_set(settings, CIPHER_KEY);
                    reset_if_set(settings, LEGACY_KEY);
                    return true;
                }
            } catch (GLib.Error e) {
                // Fall through to tier 2.
            }

            var blob = AppManager.Crypto.encrypt(trimmed);
            if (blob != null) {
                settings.set_string(CIPHER_KEY, blob);
                // Keep exactly one copy: drop any keyring entry and legacy key.
                clear_keyring();
                reset_if_set(settings, LEGACY_KEY);
                return true;
            }

            return false;
        }

        /** Clears the token from both tiers and the legacy plaintext key. */
        public static void clear_token() {
            clear_keyring();
            var settings = new GLib.Settings(APPLICATION_ID);
            reset_if_set(settings, CIPHER_KEY);
            reset_if_set(settings, LEGACY_KEY);
        }

        private static void reset_if_set(GLib.Settings settings, string key) {
            if (settings.get_string(key) != "") {
                settings.reset(key);
            }
        }

        private static void clear_keyring() {
            try {
                var schema = build_schema();
                Secret.password_clear_sync(schema, null, "application", APP_ATTR);
            } catch (GLib.Error e) {
                // No Secret Service, or nothing stored: nothing to do.
            }
        }

        /**
         * One-time lazy migration: if the legacy plaintext key still holds a
         * token, move it into a tier and reset the legacy key. Lazy migration
         * covers both the GUI and the --background-update entry points with a
         * single code path. Note: it cannot scrub old config backups — users
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
