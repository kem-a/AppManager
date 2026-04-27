namespace AppManager.Core {
    public class AppPaths {
        /**
         * Returns the AppImage path if running as an AppImage, null otherwise.
         */
        public static string? appimage_path {
            owned get {
                var path = Environment.get_variable("APPIMAGE");
                if (path != null && path.strip() != "") {
                    return path;
                }
                return null;
            }
        }

        /**
         * Returns true if the application is running as an AppImage.
         */
        public static bool is_running_as_appimage {
            get {
                return appimage_path != null;
            }
        }

        public static string data_dir {
            owned get {
                var dir = Path.build_filename(Environment.get_user_data_dir(), DATA_DIRNAME);
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        public static string registry_file {
            owned get {
                return Path.build_filename(data_dir, REGISTRY_FILENAME);
            }
        }

        public static string custom_values_file {
            owned get {
                return Path.build_filename(data_dir, CUSTOM_VALUES_FILENAME);
            }
        }

        public static string updates_log_file {
            owned get {
                return Path.build_filename(data_dir, UPDATES_LOG_FILENAME);
            }
        }

        public static string staged_updates_file {
            owned get {
                return Path.build_filename(data_dir, STAGED_UPDATES_FILENAME);
            }
        }

        /**
         * Returns the default applications directory (~/Applications).
         * This is used as fallback when no custom path is configured.
         */
        public static string default_applications_dir {
            owned get {
                return Path.build_filename(Environment.get_home_dir(), APPLICATIONS_DIRNAME);
            }
        }

        /**
         * Returns the current applications directory.
         * Uses custom path from GSettings if set, otherwise defaults to ~/Applications.
         * Note: This does NOT create the directory - callers should use ensure_applications_dir()
         * when they need to write to the directory.
         */
        public static string applications_dir {
            owned get {
                var settings = new Settings(APPLICATION_ID);
                var custom = settings.get_string("applications-dir");
                if (custom != null && custom.strip() != "") {
                    return custom.strip();
                }
                return default_applications_dir;
            }
        }

        /**
         * Ensures the applications directory exists and returns its path.
         * Creates the directory if it doesn't exist.
         */
        public static string ensure_applications_dir() {
            var dir = applications_dir;
            DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        /**
         * Returns true if `path` is inside the configured applications directory
         * or any of its subdirectories. Used to refuse installs sourced from the
         * install folder itself (e.g. accidental re-drags of already-installed
         * AppImages).
         */
        public static bool is_inside_applications_dir(string path) {
            var src = File.new_for_path(path);
            var apps = File.new_for_path(applications_dir);
            return apps.equal(src) || src.has_prefix(apps);
        }

        public static string extracted_root {
            owned get {
                var dir = Path.build_filename(applications_dir, EXTRACTED_DIRNAME);
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        public static string desktop_dir {
            owned get {
                var dir = Path.build_filename(Environment.get_user_data_dir(), "applications");
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        public static string icons_dir {
            owned get {
                var dir = Path.build_filename(Environment.get_user_data_dir(), "icons");
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        /**
         * Path to AppManager's main icon in the hicolor theme.
         */
        public static string main_icon_path {
            owned get {
                return Path.build_filename(Environment.get_user_data_dir(),
                    "icons", "hicolor", "scalable", "apps", "com.github.AppManager.svg");
            }
        }

        /**
         * Path to AppManager's symbolic icon in the hicolor theme.
         */
        public static string symbolic_icon_path {
            owned get {
                return Path.build_filename(Environment.get_user_data_dir(),
                    "icons", "hicolor", "symbolic", "apps", "com.github.AppManager-symbolic.svg");
            }
        }

        /**
         * Returns the user-specific executable directory.
         * Follows, in order:
         *   1. $XDG_BIN_HOME (if set and absolute)
         *   2. $HOME/.local/bin (fallback)
         */
        public static string local_bin_dir {
            owned get {
                string dir;
                var xdg_bin_home = Environment.get_variable("XDG_BIN_HOME");
                if (xdg_bin_home != null && xdg_bin_home.strip() != "" && Path.is_absolute(xdg_bin_home.strip())) {
                    dir = xdg_bin_home.strip();
                } else {
                    dir = Path.build_filename(Environment.get_home_dir(), LOCAL_BIN_DEFAULT_DIRNAME);
                }
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        /**
         * Returns the path to the zsync2 binary if available, null otherwise.
         * Searches in the following order:
         *   1. APP_MANAGER_ZSYNC_PATH environment variable
         *   2. System PATH (covers native installs and AppImages, where the
         *      bundled bin dir is prepended to $PATH by AppRun)
         *   3. Legacy zsync fallback
         */
        public static string? zsync_path {
            owned get {
                // 1. Explicit environment override (full path to binary)
                var env_path = Environment.get_variable("APP_MANAGER_ZSYNC_PATH");
                if (env_path != null && env_path.strip() != "" && 
                    FileUtils.test(env_path.strip(), FileTest.IS_EXECUTABLE)) {
                    return env_path.strip();
                }

                // 2. PATH lookup
                var found = Environment.find_program_in_path("zsync2");
                if (found != null && found.strip() != "") {
                    return found;
                }

                // 3. Legacy zsync as final fallback
                found = Environment.find_program_in_path("zsync");
                if (found != null && found.strip() != "") {
                    return found;
                }

                return null;
            }
        }

        /**
         * Returns true if zsync2 (or compatible zsync) is available.
         */
        public static bool zsync_available {
            get {
                return zsync_path != null;
            }
        }

        public static string? current_executable_path {
            owned get {
                // If running as an AppImage, use the original AppImage path
                var appimage_path = Environment.get_variable("APPIMAGE");
                if (appimage_path != null && appimage_path.strip() != "") {
                    return appimage_path;
                }

                try {
                    var path = GLib.FileUtils.read_link("/proc/self/exe");
                    if (path != null && path.strip() != "") {
                        return path;
                    }
                } catch (Error e) {
                    warning("Failed to resolve self executable: %s", e.message);
                }
                return null;
            }
        }
    }
}
