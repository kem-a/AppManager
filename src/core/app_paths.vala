using Gee;

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

        public static string applications_dir {
            owned get {
                var dir = Path.build_filename(Environment.get_home_dir(), APPLICATIONS_DIRNAME);
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
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

        public static string local_bin_dir {
            owned get {
                var dir = Path.build_filename(Environment.get_home_dir(), LOCAL_BIN_DIRNAME);
                DirUtils.create_with_parents(dir, 0755);
                return dir;
            }
        }

        /**
         * Returns the path to the zsync2 binary if available, null otherwise.
         * Searches in the following order:
         *   1. APP_MANAGER_ZSYNC_PATH environment variable
         *   2. Build-time bundle directory (ZSYNC_BUNDLE_DIR)
         *   3. Relative to APPDIR when running as AppImage
         *   4. System PATH
         */
        public static string? zsync_path {
            owned get {
                // 1. Environment override
                var env_path = Environment.get_variable("APP_MANAGER_ZSYNC_PATH");
                if (env_path != null && env_path.strip() != "" && 
                    FileUtils.test(env_path.strip(), FileTest.IS_EXECUTABLE)) {
                    return env_path.strip();
                }

                var candidates = new Gee.ArrayList<string>();

                // 2. Build-time bundle dir
                if (ZSYNC_BUNDLE_DIR != null && ZSYNC_BUNDLE_DIR.strip() != "") {
                    var bundle_dir = ZSYNC_BUNDLE_DIR.strip();
                    candidates.add(Path.build_filename(bundle_dir, "zsync2"));

                    // 3. Relative to APPDIR when running as AppImage
                    var appdir = Environment.get_variable("APPDIR");
                    if (appdir != null && appdir != "") {
                        var relative_bundle_dir = bundle_dir;
                        if (relative_bundle_dir.has_prefix("/")) {
                            relative_bundle_dir = relative_bundle_dir.substring(1);
                        }
                        candidates.add(Path.build_filename(appdir, relative_bundle_dir, "zsync2"));
                    }
                }

                // Check candidates
                foreach (var candidate in candidates) {
                    if (FileUtils.test(candidate, FileTest.IS_EXECUTABLE)) {
                        return candidate;
                    }
                }

                // 4. System PATH fallback
                var found = Environment.find_program_in_path("zsync2");
                if (found != null && found.strip() != "") {
                    return found;
                }

                // Try legacy zsync as final fallback
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
