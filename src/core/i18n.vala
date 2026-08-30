/**
 * Internationalization support following GNOME/GTK conventions.
 * After calling i18n_init(), use GLib._() for translations.
 */

namespace AppManager.Core {
    public const string GETTEXT_PACKAGE = "app-manager";

    private bool i18n_initialized = false;

    /**
     * Initialize internationalization. Call once at application startup.
     * After this, use _() from GLib for all translations.
     */
    public void i18n_init() {
        if (i18n_initialized) return;
        i18n_initialized = true;

        // Try the user's locale from environment; if unsupported, try common UTF-8 fallbacks.
        // When falling back, also update environment variables so that GTK's internal
        // setlocale(LC_ALL, "") call (during gtk_init) won't fail with a C locale warning.
        if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
            string fallback;
            if (Intl.setlocale(LocaleCategory.ALL, "C.UTF-8") != null) {
                fallback = "C.UTF-8";
            } else {
                Intl.setlocale(LocaleCategory.ALL, "C");
                fallback = "C";
            }
            Environment.set_variable("LC_ALL", fallback, true);
            Environment.set_variable("LANG", fallback, true);
        }
        Intl.bindtextdomain(GETTEXT_PACKAGE, get_locale_dir());
        Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain(GETTEXT_PACKAGE);
    }

    /**
     * Get the current locale's language code (e.g. "lv", "de", "pt_BR").
     * Returns null if locale is "C", "POSIX", or could not be determined.
     */
    public string? get_locale_code() {
        // get_language_names() returns e.g. ["lv_LV", "lv", "C"] - pick the shortest non-C code
        var langs = Intl.get_language_names();
        string? best = null;
        foreach (var lang in langs) {
            if (lang == "C" || lang == "POSIX" || lang == "") continue;
            // Skip variants with encoding (e.g. "lv_LV.UTF-8")
            if (lang.contains(".")) continue;
            // Prefer shorter codes (e.g. "lv" over "lv_LV"), but keep regional like "pt_BR"
            if (best == null || lang.length < best.length) {
                best = lang;
            }
        }
        return best;
    }

    /**
     * Determine the locale directory with AppImage and development support.
     */
    private string get_locale_dir() {
        // First check if we're running from AppImage
        var appdir = Environment.get_variable("APPDIR");
        if (appdir != null && appdir != "") {
            return Path.build_filename(appdir, "usr", "share", "locale");
        }

        // Check for development/local installation
        try {
            var exe_path = FileUtils.read_link("/proc/self/exe");
            if (exe_path != null) {
                var exe_dir = Path.get_dirname(exe_path);
                var local_locale = Path.build_filename(exe_dir, "..", "share", "locale");
                if (FileUtils.test(local_locale, FileTest.IS_DIR)) {
                    return local_locale;
                }
            }
        } catch (FileError e) {
            // Fall through to default
        }

        // Default system locale directory
        return "/usr/share/locale";
    }
}
