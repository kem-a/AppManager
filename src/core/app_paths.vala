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
         * Returns the current applications directory - the *main* installation
         * path. Uses custom path from GSettings if set, otherwise defaults to
         * ~/Applications. Every installed app is reachable from here, either
         * directly or through the symlink created for it (see symlink_path_for).
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
         * Extra installation paths the user added, in the order they were added.
         * Apps stored on one of these keep their files on that drive; only a
         * symlink lives in the main installation path.
         *
         * Entries are validated on read so a stale or hand-edited setting cannot
         * poison installs: absolute, non-empty, unique, and neither equal to nor
         * overlapping the main path (a path nested inside the main folder would
         * add nothing - its apps are already visible there).
         */
        public static string[] additional_installation_dirs {
            owned get {
                var stored = new Settings(APPLICATION_ID).get_strv("additional-installation-paths");
                var main = applications_dir;
                var kept = new Gee.ArrayList<string>();
                foreach (var raw in stored) {
                    if (raw == null) {
                        continue;
                    }
                    var path = normalize_dir(raw.strip());
                    if (path == null || !Path.is_absolute(path)) {
                        continue;
                    }
                    if (paths_overlap(path, main)) {
                        continue;
                    }
                    if (kept.contains(path)) {
                        continue;
                    }
                    kept.add(path);
                }
                return kept.to_array();
            }
        }

        /**
         * Main path first, then every additional path - the full set of
         * directories AppManager may install into or find an app in.
         */
        public static string[] all_installation_dirs {
            owned get {
                var additional = additional_installation_dirs;
                var result = new string[additional.length + 1];
                result[0] = applications_dir;
                for (int i = 0; i < additional.length; i++) {
                    result[i + 1] = additional[i];
                }
                return result;
            }
        }

        /**
         * Where a fresh installation is stored: the configured target when it
         * names a path that still exists in the settings, the main path
         * otherwise. Individual installs may pass their own choice instead
         * (Installer.install's target_root parameter).
         */
        public static string install_target_dir {
            owned get {
                var settings = new Settings(APPLICATION_ID);
                var target = settings.get_string("install-target");
                if (target == null || target.strip() == "") {
                    return applications_dir;
                }
                target = target.strip();
                if (target == applications_dir) {
                    return applications_dir;
                }
                foreach (var root in additional_installation_dirs) {
                    if (root == target) {
                        return root;
                    }
                }
                return applications_dir;
            }
        }

        /**
         * The installation path an app should live on. Upgrades keep the path
         * they already use - including one dropped from the settings, so an app
         * on a drive that is only occasionally mounted is not pulled onto
         * another drive by an update. Fresh installs use install_target_dir.
         */
        public static string resolve_install_root(string? current_installed_path) {
            if (current_installed_path != null && current_installed_path.strip() != "") {
                var current = current_installed_path.strip();
                // Longest match wins, so nested paths resolve to the inner one
                var configured = installation_dir_containing(current);
                if (configured != null) {
                    return configured;
                }

                // Not under any configured path any more - possibly because its
                // drive is unmounted. Keep the app where it is rather than
                // relocating it behind the user's back: for an extracted install
                // that means the folder holding .installed, for a portable one
                // the folder holding the AppImage. Deliberately not conditioned
                // on the directory currently existing - a path that is merely
                // unmounted must not turn an upgrade into a move to another
                // drive (ensure_installation_dir reports it as unavailable).
                var parent = Path.get_dirname(current);
                if (Path.get_basename(parent) == EXTRACTED_DIRNAME) {
                    parent = Path.get_dirname(parent);
                }
                if (parent != null && parent != "/" && parent != ".") {
                    return parent;
                }
            }
            return install_target_dir;
        }

        /**
         * The configured installation path `path` belongs to, or null when it is
         * in none of them. Used to tell the user which folder an existing file is
         * already inside.
         */
        public static string? installation_dir_containing(string? path) {
            if (path == null || path.strip() == "") {
                return null;
            }
            string? best = null;
            foreach (var root in all_installation_dirs) {
                if (path_is_inside(root, path) && (best == null || root.length > best.length)) {
                    best = root;
                }
            }
            return best;
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
         * Makes sure an installation root exists, returning false when it does
         * not and cannot be brought back. The main path is created on demand
         * (it may not exist yet on a fresh account); additional paths are created
         * when they are added, so one missing at install time means its drive is
         * not mounted - recreating the tree would land it on the root filesystem.
         */
        public static bool ensure_installation_dir(string dir) {
            if (FileUtils.test(dir, FileTest.IS_DIR)) {
                return true;
            }
            if (dir == applications_dir) {
                return DirUtils.create_with_parents(dir, 0755) == 0;
            }
            return false;
        }

        /**
         * Returns true if `path` is inside any configured installation path or
         * one of its subdirectories. Used to refuse installs sourced from the
         * install folders themselves (e.g. accidental re-drags of already
         * installed AppImages) and to recognize what we installed.
         */
        public static bool is_inside_applications_dir(string path) {
            foreach (var root in all_installation_dirs) {
                if (path_is_inside(root, path)) {
                    return true;
                }
            }
            return false;
        }

        /**
         * Whether `path` is `dir` itself or lives below it. Compared on
         * components (a trailing "/" is ignored), so /home/u/Applications-2 is
         * not inside /home/u/Applications.
         */
        public static bool path_is_inside(string dir, string? path) {
            if (dir == null || path == null) {
                return false;
            }
            var base_dir = dir;
            while (base_dir.length > 1 && base_dir.has_suffix("/")) {
                base_dir = base_dir.substring(0, base_dir.length - 1);
            }
            var candidate = path;
            while (candidate.length > 1 && candidate.has_suffix("/")) {
                candidate = candidate.substring(0, candidate.length - 1);
            }
            return candidate == base_dir || candidate.has_prefix(base_dir + "/");
        }

        /**
         * The location in the main installation directory that shows the app
         * stored at `installed_path`: <main>/<same relative path>. Null when the
         * app is already in the main directory, or when `installed_path` is not
         * under a configured additional path.
         */
        public static string? symlink_path_for(string? installed_path) {
            if (installed_path == null || installed_path.strip() == "") {
                return null;
            }
            var path = installed_path.strip();
            var main = applications_dir;
            if (path_is_inside(main, path)) {
                return null;   // already in the regular location
            }
            foreach (var root in additional_installation_dirs) {
                if (path_is_inside(root, path)) {
                    var relative = path.substring(root.length);
                    while (relative.has_prefix("/")) {
                        relative = relative.substring(1);
                    }
                    return Path.build_filename(main, relative);
                }
            }
            return null;
        }

        /**
         * Creates (or re-points) the symlink that shows `installed_path` in the
         * main installation directory, so an app stored on another drive stays
         * visible in the regular folder. `link_path` is a link recorded on an
         * earlier install of the same app; when it is null the location is
         * derived from the installed path.
         *
         * Returns the link to record on the installation, or null when the app
         * needs none (it lives in the main directory) or the link could not be
         * created - a missing link never fails an install.
         */
        public static string? sync_installation_symlink(string installed_path, string? link_path, string? main_dir = null) {
            if (installed_path == null || installed_path.strip() == "") {
                return null;
            }
            var target = link_path != null && link_path.strip() != "" ? link_path.strip() : symlink_path_for(installed_path);
            if (target == null) {
                return null;
            }
            var main = main_dir != null && main_dir.strip() != "" ? main_dir.strip() : applications_dir;
            if (!path_is_inside(main, target)) {
                // Never link outside the main folder: the record would point at
                // something the settings no longer describe.
                return null;
            }

            DirUtils.create_with_parents(Path.get_dirname(target), 0755);
            var link = File.new_for_path(target);

            FileInfo? info = null;
            try {
                info = link.query_info(
                    FileAttribute.STANDARD_IS_SYMLINK + "," + FileAttribute.STANDARD_SYMLINK_TARGET,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            } catch (Error e) {
                info = null;   // absent: nothing in the way
            }

            if (info != null) {
                if (info.get_is_symlink()) {
                    var existing = resolve_link_target(target, info.get_symlink_target());
                    if (existing == installed_path) {
                        return target;   // already correct (e.g. re-install over the same path)
                    }
                    if (existing != null && !File.new_for_path(existing).query_exists()) {
                        // Dangling link left by an unmounted drive or an older
                        // version of the app: ours to reuse.
                        try {
                            link.delete(null);
                        } catch (Error e) {
                            warning("Failed to replace stale install link %s: %s", target, e.message);
                            return null;
                        }
                    } else {
                        target = Utils.FileUtils.unique_path(target);
                        link = File.new_for_path(target);
                    }
                } else if (link.query_exists()) {
                    // A real file or folder sits where the link belongs - not ours
                    // to overwrite, so link beside it.
                    target = Utils.FileUtils.unique_path(target);
                    link = File.new_for_path(target);
                }
            }

            try {
                link.make_symbolic_link(installed_path, null);
            } catch (Error e) {
                warning("Failed to link %s into %s: %s", installed_path, target, e.message);
                return null;
            }
            debug("Linked %s -> %s", target, installed_path);
            return target;
        }

        /**
         * Removes the symlink showing `installed_path` in the main installation
         * directory. Only a link that still points where we put it is touched:
         * a real file that replaced it, or a link the user repointed, is left
         * alone. Absent links are not an error.
         */
        public static void remove_installation_symlink(string? link_path, string? installed_path = null) {
            if (link_path == null || link_path.strip() == "") {
                return;
            }
            var path = link_path.strip();
            var link = File.new_for_path(path);
            try {
                var info = link.query_info(
                    FileAttribute.STANDARD_IS_SYMLINK + "," + FileAttribute.STANDARD_SYMLINK_TARGET,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                if (!info.get_is_symlink()) {
                    return;
                }
                var target = resolve_link_target(path, info.get_symlink_target());
                if (target == null) {
                    return;
                }
                if (installed_path != null && installed_path.strip() != "") {
                    if (target != installed_path.strip()) {
                        return;
                    }
                } else if (!points_into_additional_installation_dir(target)) {
                    return;
                }
                link.delete(null);
                debug("Removed install link %s", path);
            } catch (Error e) {
                // Absent, or unreadable: nothing to clean up
            }
        }

        private static bool points_into_additional_installation_dir(string target) {
            foreach (var root in additional_installation_dirs) {
                if (path_is_inside(root, target)) {
                    return true;
                }
            }
            return false;
        }

        /** Turns a possibly relative symlink target into an absolute path. */
        private static string? resolve_link_target(string link_path, string? target) {
            if (target == null || target.strip() == "") {
                return null;
            }
            var resolved = target.strip();
            if (!Path.is_absolute(resolved)) {
                resolved = Path.build_filename(Path.get_dirname(link_path), resolved);
            }
            return resolved;
        }

        /** Strips trailing slashes; returns null for an empty/root-less value. */
        private static string? normalize_dir(string path) {
            if (path == null || path == "") {
                return null;
            }
            var normalized = path;
            while (normalized.length > 1 && normalized.has_suffix("/")) {
                normalized = normalized.substring(0, normalized.length - 1);
            }
            return normalized;
        }

        /** True when the two paths are equal or one contains the other. */
        private static bool paths_overlap(string a, string b) {
            return path_is_inside(a, b) || path_is_inside(b, a);
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
         * Returns the path to the zsync-rs client if available, null otherwise.
         * Searches in the following order:
         *   1. APP_MANAGER_ZSYNC_PATH environment variable
         *   2. Bundled zsync-rs on the system PATH (covers native installs and
         *      AppImages, where the bundled bin dir is prepended to $PATH by AppRun)
         * Other zsync clients are not used: only zsync-rs reports progress, and
         * stock zsync cannot fetch https URLs.
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
                var found = Environment.find_program_in_path("zsync-rs");
                if (found != null && found.strip() != "") {
                    return found;
                }

                return null;
            }
        }

        /**
         * Returns true if a zsync client is available.
         */
        public static bool zsync_available {
            get {
                return zsync_path != null;
            }
        }

        /**
         * Directory holding one <record-id>.sandbox manifest per sandboxed app.
         * Regenerated by the installer whenever sandbox permissions change; read
         * by the sandbox-run launcher on every launch.
         */
        public static string sandbox_dir {
            owned get {
                var dir = Path.build_filename(data_dir, SANDBOX_DIRNAME);
                DirUtils.create_with_parents(dir, 0700);
                return dir;
            }
        }

        /**
         * Path to a record's sandbox manifest. Does not create the file.
         */
        public static string sandbox_manifest_file(string record_id) {
            return Path.build_filename(sandbox_dir, "%s%s".printf(record_id, SANDBOX_MANIFEST_SUFFIX));
        }

        /**
         * The value $XDG_RUNTIME_DIR has, or should have. The sandbox reproduces this
         * path inside itself as a tmpfs, so it has to be a single answer that holds on
         * both sides - hence the explicit fallback rather than leaving it unset, which
         * only happens outside a normal login session.
         */
        public static string sandbox_runtime_base {
            owned get {
                var runtime = Environment.get_variable("XDG_RUNTIME_DIR");
                if (runtime != null && runtime.strip() != "" && Path.is_absolute(runtime.strip())) {
                    return runtime.strip();
                }
                var fallback = Path.build_filename(Environment.get_tmp_dir(),
                    "%s-runtime-%u".printf(DATA_DIRNAME, (uint) Posix.getuid()));
                DirUtils.create_with_parents(fallback, 0700);
                return fallback;
            }
        }

        /**
         * Per-session sandbox runtime root: FUSE mounts, D-Bus proxy sockets and
         * per-launch instance state live here, so the whole lot disappears at logout
         * even if a supervisor was killed mid-flight.
         */
        public static string sandbox_runtime_dir {
            owned get {
                var dir = Path.build_filename(sandbox_runtime_base, DATA_DIRNAME);
                DirUtils.create_with_parents(dir, 0700);
                return dir;
            }
        }

        /**
         * Path to the bubblewrap binary, or null when it is not installed.
         * Same resolution order as zsync_path: explicit override, then PATH.
         *
         * bwrap is deliberately not bundled - it may be setuid on some distros, and
         * a bundled copy would lose that.
         */
        public static string? bwrap_path {
            owned get {
                return resolve_tool("APP_MANAGER_BWRAP_PATH", "bwrap");
            }
        }

        /**
         * Path to xdg-dbus-proxy, or null when it is not installed. Needed by any
         * sandbox that filters the bus rather than binding the real socket, which is
         * every sandbox that is not given the open session bus.
         */
        public static string? xdg_dbus_proxy_path {
            owned get {
                return resolve_tool("APP_MANAGER_DBUS_PROXY_PATH", "xdg-dbus-proxy");
            }
        }

        /**
         * Whether sandboxing can be offered at all. AppManager running inside a
         * Flatpak has no usable bwrap of its own, so the feature is hidden there
         * (see Installer.is_flatpak_sandbox).
         */
        public static bool sandbox_available {
            get {
                if (FileUtils.test("/.flatpak-info", FileTest.EXISTS)) {
                    return false;
                }
                return bwrap_path != null;
            }
        }

        /**
         * Path to the squashfuse FUSE driver the sandbox mounts SquashFS AppImages
         * with, or null when it is unavailable. This is the *driver*, a different
         * binary from the unsquashfs extractor used elsewhere.
         */
        public static string? squashfuse_path {
            owned get {
                return resolve_bundled_tool("APP_MANAGER_SQUASHFUSE_PATH", null, "squashfuse");
            }
        }

        /**
         * Path to the dwarfs FUSE driver, or null when it is unavailable. Same
         * relationship to dwarfsextract as squashfuse has to unsquashfs, and it ships
         * in the same tarball - hence the shared APP_MANAGER_DWARFS_DIR override.
         */
        public static string? dwarfs_fuse_path {
            owned get {
                return resolve_bundled_tool("APP_MANAGER_DWARFS_PATH", "APP_MANAGER_DWARFS_DIR", "dwarfs");
            }
        }

        /**
         * Resolves a helper binary: explicit environment override first, then PATH -
         * which covers both a native install and the bundled copy an AppImage's AppRun
         * prepends to $PATH.
         */
        private static string? resolve_tool(string env_var, string program) {
            var env_path = Environment.get_variable(env_var);
            if (env_path != null && env_path.strip() != ""
                && FileUtils.test(env_path.strip(), FileTest.IS_EXECUTABLE)) {
                return env_path.strip();
            }
            var found = Environment.find_program_in_path(program);
            if (found != null && found.strip() != "") {
                return found;
            }
            return null;
        }

        /**
         * Same as resolve_tool, plus the locations a bundled helper is unpacked to.
         * Mirrors the search order AppImageAssets uses for its extractors, so the
         * driver and the extractor of one format are always found the same way.
         */
        private static string? resolve_bundled_tool(string env_path_var, string? env_dir_var, string program) {
            var env_path = Environment.get_variable(env_path_var);
            if (env_path != null && env_path.strip() != ""
                && FileUtils.test(env_path.strip(), FileTest.IS_EXECUTABLE)) {
                return env_path.strip();
            }

            if (env_dir_var != null) {
                var env_dir = Environment.get_variable(env_dir_var);
                if (env_dir != null && env_dir.strip() != "") {
                    var path = Path.build_filename(env_dir.strip(), program);
                    if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                        return path;
                    }
                }
            }

            var xdg_data_home = Environment.get_variable("XDG_DATA_HOME");
            if (xdg_data_home == null || xdg_data_home.strip() == "") {
                xdg_data_home = Path.build_filename(Environment.get_home_dir(), ".local", "share");
            }

            string[] candidates = {
                Path.build_filename(xdg_data_home, DATA_DIRNAME, "dwarfs", program),
                Path.build_filename(Environment.get_home_dir(), ".local", "share", DATA_DIRNAME, "dwarfs", program),
                Path.build_filename("/usr/lib/appimage-thumbnailer", program),
                Path.build_filename("/usr/lib/app-manager", program)
            };
            foreach (var path in candidates) {
                if (FileUtils.test(path, FileTest.IS_EXECUTABLE)) {
                    return path;
                }
            }

            var found = Environment.find_program_in_path(program);
            if (found != null && found.strip() != "") {
                return found;
            }
            return null;
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
