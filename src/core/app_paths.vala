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
                var dir = Path.build_filename(Environment.get_user_data_dir(), "icons", "hicolor", "scalable", "apps");
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
