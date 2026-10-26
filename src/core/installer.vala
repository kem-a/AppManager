using AppManager.Utils;
using Gee;

namespace AppManager.Core {
    public errordomain InstallerError {
        DESKTOP_MISSING,
        EXTRACTION_FAILED,
        INCOMPATIBLE_ARCHITECTURE,
        SEVEN_ZIP_MISSING,
        UNINSTALL_FAILED,
        UNKNOWN
    }

    public class Installer : Object {
        private InstallationRegistry registry;
        private Settings settings;
        private string[] uninstall_prefix;
        private AppHubFetch? policy_fetch;

        public signal void progress(string message);

        public Installer(InstallationRegistry registry, Settings settings, owned AppHubFetch? policy_fetch = null) {
            this.registry = registry;
            this.settings = settings;
            this.policy_fetch = (owned) policy_fetch;
            this.uninstall_prefix = resolve_uninstall_prefix();
        }

        public InstallationRecord install(string file_path, InstallMode override_mode = InstallMode.PORTABLE, AppHubPolicy? policy = null, string? target_root = null) throws Error {
            return install_sync(file_path, override_mode, null, policy, target_root);
        }

        public InstallationRecord upgrade(string file_path, InstallationRecord old_record, AppHubPolicy? policy = null, string? target_root = null) throws Error {
            return reinstall(file_path, old_record, old_record.mode, policy, target_root);
        }

        /**
         * Returns the path to the AppImage portable-home folder for this record
         * (<installed_path>.home). Only meaningful for PORTABLE mode.
         */
        public static string get_portable_home_path(InstallationRecord record) {
            return "%s.home".printf(record.installed_path ?? "");
        }

        /**
         * Returns the path to the AppImage portable-config folder for this record
         * (<installed_path>.config). Only meaningful for PORTABLE mode.
         */
        public static string get_portable_config_path(InstallationRecord record) {
            return "%s.config".printf(record.installed_path ?? "");
        }

        private static bool portable_mode_applicable(InstallationRecord record) {
            return record.mode == InstallMode.PORTABLE && record.installed_path != null && record.installed_path.strip() != "";
        }

        private static bool is_self_record(InstallationRecord record) {
            return record.is_self_app();
        }

        /**
         * True when the .home folder exists next to the AppImage.
         */
        public static bool has_portable_home(InstallationRecord record) {
            if (!portable_mode_applicable(record)) {
                return false;
            }
            return File.new_for_path(get_portable_home_path(record)).query_exists();
        }

        /**
         * True when the .config folder exists next to the AppImage.
         */
        public static bool has_portable_config(InstallationRecord record) {
            if (!portable_mode_applicable(record)) {
                return false;
            }
            return File.new_for_path(get_portable_config_path(record)).query_exists();
        }

        /**
         * True when either portable folder exists. Convenience for flows that don't
         * need to distinguish between .home and .config.
         */
        public static bool has_portable_folders(InstallationRecord record) {
            return has_portable_home(record) || has_portable_config(record);
        }

        /**
         * True when a portable folder holds something worth migrating. An empty one
         * still has to go, but it raises no question about what to do with it.
         */
        public static bool has_portable_data(InstallationRecord record) {
            foreach (var path in new string[] { get_portable_home_path(record),
                                                get_portable_config_path(record) }) {
                if (GLib.FileUtils.test(path, FileTest.IS_DIR)
                    && !Utils.FileUtils.dir_is_effectively_empty(path)) {
                    return true;
                }
            }
            return false;
        }

        /**
         * True when the sandboxed home exists at all. Uninstall offers to keep or
         * remove user data, and for a sandboxed app this folder is all of it.
         */
        public static bool has_sandbox_home(InstallationRecord record) {
            return GLib.FileUtils.test(SandboxConfig.sandbox_home_path(record), FileTest.IS_DIR);
        }

        /**
         * True when the sandboxed home already holds data of its own, which is what
         * turns migrating the portable folders in from a move into a choice.
         */
        public static bool sandbox_home_has_data(InstallationRecord record) {
            var path = SandboxConfig.sandbox_home_path(record);
            return GLib.FileUtils.test(path, FileTest.IS_DIR)
                && !Utils.FileUtils.dir_is_effectively_empty(path);
        }

        /**
         * Creates the .home folder next to the AppImage. Safe to call if it already exists.
         */
        public void create_portable_home(InstallationRecord record) {
            if (!portable_mode_applicable(record) || is_self_record(record) || record.sandbox_enabled()) {
                return;
            }
            DirUtils.create_with_parents(get_portable_home_path(record), 0755);
        }

        /**
         * Creates the .config folder next to the AppImage. Safe to call if it already exists.
         */
        public void create_portable_config(InstallationRecord record) {
            if (!portable_mode_applicable(record) || is_self_record(record) || record.sandbox_enabled()) {
                return;
            }
            DirUtils.create_with_parents(get_portable_config_path(record), 0755);
        }

        /**
         * Moves the app's portable folders into its sandboxed home, so switching the
         * sandbox on does not leave the app's data behind.
         *
         * It has to move rather than be read in place: only the AppImage runtime reads
         * a portable folder, and a sandboxed launch never runs it - the payload is
         * mounted outside and AppRun is executed directly. So a .home left where it is
         * would simply stop being read.
         *
         * .home is the app's $HOME and so is the sandboxed home, so its contents cross
         * over directly. .config is the app's $XDG_CONFIG_HOME, which the sandbox does
         * not set, so it lands in .config inside that home.
         *
         * The sources are removed rather than emptied. An empty .home is still adopted
         * by the runtime on an unsandboxed launch, and the details window reads the
         * folder's existence as the toggle's state, so leaving one behind would make
         * both lie.
         *
         * With `replace`, whatever the sandboxed home already held is deleted first.
         * Otherwise it wins every name collision, which is what the conflict dialog
         * offers as "Merge".
         */
        public void migrate_portable_to_sandbox(InstallationRecord record, bool replace) {
            if (!portable_mode_applicable(record) || !has_portable_folders(record)) {
                return;
            }
            var sandbox = SandboxConfig.sandbox_home_path(record);
            if (replace && GLib.FileUtils.test(sandbox, FileTest.IS_DIR)) {
                Utils.FileUtils.remove_dir_recursive(sandbox);
            }
            if (DirUtils.create_with_parents(sandbox, 0700) != 0) {
                warning("Cannot create sandboxed home %s: %s", sandbox, Posix.strerror(Posix.errno));
                return;
            }
            // .config first. With both folders active the runtime points
            // XDG_CONFIG_HOME at .config, which makes any .config *inside* .home stale
            // leftovers from before it was turned on. Moving the live copy in first
            // means the stale one loses the name collision rather than winning it.
            move_into(get_portable_config_path(record), Path.build_filename(sandbox, ".config"));
            move_into(get_portable_home_path(record), sandbox);
        }

        /**
         * Moves every entry of `source` into `dest` and then removes `source`.
         *
         * A name already taken in `dest` is descended into when both sides are
         * directories, and otherwise left alone: the destination copy wins, which is
         * the merge rule the dialog states. Names are collected before anything moves,
         * since moving entries out from under a live enumerator is not defined.
         */
        private static void move_into(string source, string dest) {
            if (!GLib.FileUtils.test(source, FileTest.IS_DIR)) {
                return;
            }
            if (DirUtils.create_with_parents(dest, 0700) != 0) {
                warning("Cannot create %s: %s", dest, Posix.strerror(Posix.errno));
                return;
            }
            var names = new Gee.ArrayList<string>();
            try {
                var dir = Dir.open(source);
                string? name;
                while ((name = dir.read_name()) != null) {
                    names.add(name);
                }
            } catch (FileError e) {
                warning("Cannot read %s: %s", source, e.message);
                return;
            }

            foreach (var name in names) {
                var child = Path.build_filename(source, name);
                var target = Path.build_filename(dest, name);
                if (GLib.FileUtils.test(target, FileTest.EXISTS)) {
                    if (GLib.FileUtils.test(child, FileTest.IS_DIR)
                        && GLib.FileUtils.test(target, FileTest.IS_DIR)
                        && !GLib.FileUtils.test(child, FileTest.IS_SYMLINK)) {
                        move_into(child, target);
                    }
                    continue;
                }
                try {
                    File.new_for_path(child).move(File.new_for_path(target),
                        FileCopyFlags.NOFOLLOW_SYMLINKS, null, null);
                } catch (Error e) {
                    warning("Failed to move %s to %s: %s", child, target, e.message);
                }
            }
            // Anything still here lost a name collision, and the user was told the
            // sandbox copy would be kept.
            Utils.FileUtils.remove_dir_recursive(source);
        }

        private void remove_portable_folder_at(string path, bool to_trash) {
            var file = File.new_for_path(path);
            if (!file.query_exists()) {
                return;
            }
            try {
                if (to_trash) {
                    file.trash(null);
                } else {
                    Utils.FileUtils.remove_dir_recursive(path);
                }
            } catch (Error e) {
                warning("Failed to remove portable folder %s: %s", path, e.message);
            }
        }

        /**
         * Removes only the .home folder next to the AppImage.
         * When `to_trash` is true, it is moved to trash; otherwise deleted permanently.
         */
        public void remove_portable_home(InstallationRecord record, bool to_trash) {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return;
            }
            remove_portable_folder_at(get_portable_home_path(record), to_trash);
        }

        /**
         * Removes only the .config folder next to the AppImage.
         * When `to_trash` is true, it is moved to trash; otherwise deleted permanently.
         */
        public void remove_portable_config(InstallationRecord record, bool to_trash) {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return;
            }
            remove_portable_folder_at(get_portable_config_path(record), to_trash);
        }

        /**
         * Removes the sandboxed home folder (<installed_path>.sandbox) next to the AppImage.
         * When `to_trash` is true it is moved to trash; otherwise deleted permanently.
         *
         * The sandbox's cache does not live in there — it needs a path that means the
         * same thing on the host, see SandboxBwrap.add_cache_dir — so it is removed
         * separately, and always permanently: it is a cache, and filling the trash with
         * one helps nobody.
         */
        public void remove_sandbox_home(InstallationRecord record, bool to_trash) {
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return;
            }
            remove_portable_folder_at(SandboxConfig.sandbox_home_path(record), to_trash);

            var cache = SandboxBwrap.host_cache_dir(record.sandbox_app_id);
            if (cache != null && GLib.FileUtils.test(cache, FileTest.IS_DIR)) {
                remove_portable_folder_at(cache, false);
            }
        }

        /**
         * Removes both portable folders next to the AppImage.
         */
        public void remove_portable_folders(InstallationRecord record, bool to_trash) {
            remove_portable_home(record, to_trash);
            remove_portable_config(record, to_trash);
        }

        /**
         * Full install flow: checks architecture, detects existing installation,
         * and either upgrades or installs. Sets is_upgrade to true if an existing
         * installation was replaced. With keep_both, an existing installation is
         * never replaced - the app installs side by side as a numbered copy.
         * `target_root` overrides the configured installation path for this
         * install, so a replace can also move the app to another path.
         */
        public InstallationRecord install_or_upgrade(string file_path, out bool is_upgrade, bool keep_both = false, string? target_root = null) throws Error {
            is_upgrade = false;

            var metadata = new AppImageMetadata(File.new_for_path(file_path));
            if (!metadata.is_architecture_compatible()) {
                throw new InstallerError.INCOMPATIBLE_ARCHITECTURE(
                    metadata.architecture ?? "unknown");
            }

            if (keep_both) {
                return install(file_path, InstallMode.PORTABLE, null, target_root);
            }

            var existing = detect_existing(file_path);
            if (existing != null) {
                is_upgrade = true;
                return upgrade(file_path, existing, null, target_root);
            } else {
                return install(file_path, InstallMode.PORTABLE, null, target_root);
            }
        }

        private InstallationRecord? detect_existing(string appimage_path) {
            try {
                var checksum = Utils.FileUtils.compute_checksum(appimage_path);

                string? app_name = null;
                string? temp_dir = null;
                try {
                    temp_dir = Utils.FileUtils.create_temp_dir("appmgr-detect-");
                    var desktop_file = AppImageAssets.extract_desktop_entry(appimage_path, temp_dir);
                    if (desktop_file != null) {
                        var desktop_info = AppImageAssets.parse_desktop_file(desktop_file);
                        if (desktop_info.name != null && desktop_info.name.strip() != "") {
                            app_name = desktop_info.name.strip();
                        }
                    }
                } finally {
                    if (temp_dir != null) {
                        Utils.FileUtils.remove_dir_recursive(temp_dir);
                    }
                }

                return registry.detect_existing(appimage_path, checksum, app_name);
            } catch (Error e) {
                warning("Failed to detect existing installation: %s", e.message);
            }
            return null;
        }

        public InstallationRecord reinstall(string file_path, InstallationRecord old_record, InstallMode mode, AppHubPolicy? policy = null, string? target_root = null) throws Error {
            // Validate new AppImage before touching the old installation.
            // Uses the same desktop/icon extraction that install does - if the
            // new package is corrupted or badly packed, we bail out here and
            // the currently installed version stays untouched.
            validate_appimage(file_path);
            // Resolve before uninstall: a policy/network failure must leave the old
            // installation usable. Uncatalogued upstream updates retain its policy.
            var incoming_checksum = policy != null || old_record.apphub_id != null ? Utils.FileUtils.compute_checksum(file_path) : null;
            // Parameters are borrowed; a freshly fetched template needs an owned
            // local reference through the uninstall/reinstall sequence.
            AppHubPolicy? resolved_policy = policy;
            if (resolved_policy == null && old_record.apphub_id != null) {
                resolved_policy = AppHubPolicy.resolve(null, incoming_checksum, old_record.apphub_id, null, policy_fetch);
            }
            if (resolved_policy != null && resolved_policy.sha256 != null && resolved_policy.sha256 != incoming_checksum) {
                throw new AppHubPolicyError.ARTIFACT_MISMATCH(_("The AppHub sandbox policy could not be matched to this download."));
            }
            bool preserve_permissions = old_record.apphub_policy_customized
                || (old_record.apphub_id == null && old_record.sandbox_profile != null);
            if (!preserve_permissions && !old_record.is_self_app()) {
                if (resolved_policy != null) validate_policy_install(mode);
                else if (old_record.apphub_policy != null && old_record.apphub_id != null) {
                    AppHubPolicy.parse(old_record.apphub_id, old_record.apphub_policy);
                    validate_policy_install(mode);
                }
            }

            // Preserve portable folders only when staying in PORTABLE mode (user data survives upgrades).
            // When switching to EXTRACTED the folders serve no purpose and go along with the uninstall.
            bool preserve_portable = (old_record.mode == InstallMode.PORTABLE && mode == InstallMode.PORTABLE);

            try {
                uninstall(old_record, false, preserve_portable);
            } catch (Error e) {
                // Trash may not be supported on some mounts (e.g. /opt).
                // Fall back to permanent delete so the update can proceed.
                if (e.message.has_prefix("TRASH_FAILED:")) {
                    uninstall(old_record, true, preserve_portable);
                } else {
                    throw e;
                }
            }
            return install_sync(file_path, mode, old_record, resolved_policy);
        }

        /**
         * Pre-flight validation: extracts metadata, desktop entry and icon
         * from the AppImage - the same checks install_sync/finalize performs.
         * Throws on any problem so the caller can abort before uninstalling
         * the old version.
         */
        private void validate_appimage(string file_path) throws Error {
            var file = File.new_for_path(file_path);
            var metadata = new AppImageMetadata(file);

            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-validate-");
            try {
                var desktop_path = AppImageAssets.extract_desktop_entry(metadata.path, temp_dir);
                DesktopEntry.parse_exec(new DesktopEntry(desktop_path).exec ?? "");
                AppImageAssets.extract_icon(metadata.path, temp_dir);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
        }

        private void validate_policy_install(InstallMode mode) throws Error {
            if (mode != InstallMode.PORTABLE) throw new InstallerError.UNKNOWN(_("AppHub sandbox policies require a portable installation."));
            if (!AppPaths.sandbox_available) throw new InstallerError.UNKNOWN(_("Install bubblewrap to apply the AppHub sandbox policy."));
        }

        private InstallationRecord install_sync(string file_path, InstallMode override_mode, InstallationRecord? old_record, AppHubPolicy? policy = null, string? target_root = null) throws Error {
            var file = File.new_for_path(file_path);
            var metadata = new AppImageMetadata(file);
            if (policy != null && policy.sha256 != null && policy.sha256 != metadata.checksum) {
                throw new AppHubPolicyError.ARTIFACT_MISMATCH(_("The AppHub sandbox policy could not be matched to this download."));
            }

            // Which installation path physically holds this app. An explicit
            // choice wins (the installer window can offer one); otherwise an
            // upgrade stays on the path it already uses and a fresh install uses
            // the configured target.
            string? requested_root = null;
            if (target_root != null && target_root.strip() != "" && Path.is_absolute(target_root.strip())) {
                requested_root = target_root.strip();
            }
            string install_root;
            if (requested_root != null) {
                install_root = requested_root;
            } else if (old_record != null) {
                install_root = AppPaths.resolve_install_root(old_record.installed_path);
            } else {
                install_root = AppPaths.install_target_dir;
            }
            if (!AppPaths.ensure_installation_dir(install_root)) {
                throw new InstallerError.UNKNOWN(
                    _("Installation path %s is not available. Check that the drive is mounted and try again.").printf(install_root));
            }

            InstallMode mode = override_mode;

            // Identical content may be installed side by side ("Keep Both"), so the
            // registry id gets a "-N" suffix when the checksum is already taken.
            var record = new InstallationRecord(registry.unique_record_id(metadata.checksum), metadata.display_name, mode);
            
            // Mark as in-flight immediately to prevent reconcile from interfering
            registry.mark_in_flight(record.id);
            
            record.source_path = metadata.path;
            record.source_checksum = metadata.checksum;
            
            // Preserve installed_at and set updated_at for upgrades
            if (old_record != null) {
                record.installed_at = old_record.installed_at;
                record.updated_at = (int64)GLib.get_real_time();
                // Keep the secondary-copy suffix stable across updates (frozen counter).
                record.copy_index = old_record.copy_index;
                
                // Carry over last_modified and content_length from old record
                record.last_modified = old_record.last_modified;
                record.content_length = old_record.content_length;
                // Note: last_release_tag is intentionally NOT carried over. The
                // updater sets it after a successful release-based update; for other
                // upgrade paths (manual reinstall, zsync) a stale tag would make the
                // next probe report "already current" for a release never installed.

                // Carry over zsync_update_info from old record as safety net
                // (also re-extracted from new AppImage in finalize_desktop_and_icon)
                record.zsync_update_info = old_record.zsync_update_info;
                // Note: zsync_sha1 is intentionally NOT carried over. The updater
                // sets it after a successful zsync update; for other upgrade paths
                // (manual reinstall, release-based update) it stays null so the
                // next probe recomputes it from the actual installed file.
                
                // Carry over custom values from old record (user customizations survive updates)
                record.custom_name = old_record.custom_name;
                record.custom_commandline_args = old_record.custom_commandline_args;
                record.custom_keywords = old_record.custom_keywords;
                record.custom_icon_name = old_record.custom_icon_name;
                record.custom_startup_wm_class = old_record.custom_startup_wm_class;
                record.custom_update_link = old_record.custom_update_link;
                record.custom_web_page = old_record.custom_web_page;
                record.custom_no_display = old_record.custom_no_display;
                record.custom_add_to_path = old_record.custom_add_to_path;
                record.custom_env_vars = old_record.custom_env_vars;
                record.autostart_enabled = old_record.autostart_enabled;
                record.custom_autostart_args = old_record.custom_autostart_args;
                record.custom_autostart_delay = old_record.custom_autostart_delay;
                record.prerelease_enabled = old_record.prerelease_enabled;
                // The link showing the app in the main installation folder, if it
                // has one: re-pointed after the reinstall rather than re-derived,
                // so an app stored on a path since removed from the settings keeps
                // the link it already had.
                record.symlink_path = old_record.symlink_path;
                record.copy_sandbox_from(old_record);
                // First catalog recognition must not replace existing non-store
                // permissions, including configurations made by older builds.
                if (policy != null && old_record.apphub_id == null && old_record.sandbox_profile != null) {
                    record.apphub_policy_customized = true;
                }
                // Note: original_* values will be updated from the new AppImage's .desktop
            }
            // Note: For fresh installs, history is applied in finalize_desktop_and_icon()
            // after the app name is resolved from the .desktop file
            if (policy != null) {
                record.apphub_id = policy.app_id;
                record.apphub_policy = policy.json;
            }

            bool is_upgrade = (old_record != null);

            try {
                if (mode == InstallMode.PORTABLE) {
                    install_portable(metadata, record, is_upgrade, install_root);
                    // For fresh installs, apply the global portable-mode defaults (home/config independently).
                    // Upgrades inherit existing portable folders (they stayed in place during reinstall).
                    if (old_record == null && !is_self_record(record)) {
                        if (settings.get_boolean("portable-home-default")) {
                            create_portable_home(record);
                        }
                        if (settings.get_boolean("portable-config-default")) {
                            create_portable_config(record);
                        }
                    }
                } else {
                    install_extracted(metadata, record, is_upgrade, install_root);
                }

                // An app stored on another drive is shown from the main
                // installation folder through a symlink, so every installed app
                // stays reachable from the regular location while the bytes only
                // ever land on the drive that holds the additional path.
                var previous_link = old_record != null ? old_record.symlink_path : null;
                var new_link = AppPaths.sync_installation_symlink(record.installed_path, previous_link);
                if (previous_link != null && previous_link != new_link) {
                    // The app moved paths (or its name changed): drop the link it
                    // had, which now points at the old location.
                    AppPaths.remove_installation_symlink(previous_link,
                        old_record != null ? old_record.installed_path : null);
                }
                record.symlink_path = new_link;

                // Only delete source after successful installation
                if (File.new_for_path(file_path).query_exists()) {
                    File.new_for_path(file_path).delete();
                }

                debug("Installer: calling registry.register() for %s", record.name);
                registry.register(record);
                debug("Installer: registry.register() completed");
                
                // Update MIME database so file associations work
                update_desktop_database();
                
                return record;
            } catch (Error e) {
                // Cleanup on failure and clear in-flight flag
                registry.clear_in_flight(record.id);
                cleanup_failed_installation(record);
                throw e;
            }
        }

        private void install_portable(AppImageMetadata metadata, InstallationRecord record, bool is_upgrade, string install_root) throws Error {
            progress("Preparing Applications folder…");
            record.installed_path = metadata.path;
            finalize_desktop_and_icon(record, metadata, metadata.path, metadata.path, is_upgrade, null, install_root);
        }

        private void install_extracted(AppImageMetadata metadata, InstallationRecord record, bool is_upgrade, string install_root) throws Error {
            progress("Extracting AppImage…");
            var base_name = metadata.sanitized_basename();
            var installed_root = Path.build_filename(install_root, EXTRACTED_DIRNAME);
            DirUtils.create_with_parents(installed_root, 0755);
            var dest_dir = Utils.FileUtils.unique_path(Path.build_filename(installed_root, base_name));
            string staging_dir = "";
            try {
                var staging_template = Path.build_filename(installed_root, "%s-extract-XXXXXX".printf(base_name));
                staging_dir = DirUtils.mkdtemp(staging_template);
                run_appimage_extract(metadata.path, staging_dir);
                var extracted_root = Path.build_filename(staging_dir, SQUASHFS_ROOT_DIR);
                var extracted_file = File.new_for_path(extracted_root);
                if (!extracted_file.query_exists()) {
                    throw new InstallerError.EXTRACTION_FAILED("AppImage extraction did not produce %s".printf(SQUASHFS_ROOT_DIR));
                }
                
                // Some AppImages create squashfs-root as a symlink (e.g., to AppDir).
                // Resolve the symlink to get the actual directory to move.
                var file_type = extracted_file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (file_type == FileType.SYMBOLIC_LINK) {
                    try {
                        var link_target = GLib.FileUtils.read_link(extracted_root);
                        string resolved_path;
                        if (Path.is_absolute(link_target)) {
                            resolved_path = link_target;
                        } else {
                            resolved_path = Path.build_filename(staging_dir, link_target);
                        }
                        extracted_file = File.new_for_path(resolved_path);
                        debug("%s is a symlink, resolved to: %s", SQUASHFS_ROOT_DIR, resolved_path);
                    } catch (Error e) {
                        throw new InstallerError.EXTRACTION_FAILED("Failed to resolve %s symlink: %s".printf(SQUASHFS_ROOT_DIR, e.message));
                    }
                }
                
                if (extracted_file.query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                    throw new InstallerError.EXTRACTION_FAILED("AppImage extraction did not produce a valid directory");
                }
                
                extracted_file.move(File.new_for_path(dest_dir), FileCopyFlags.NONE, null, null);
            } catch (Error e) {
                Utils.FileUtils.remove_dir_recursive(dest_dir);
                if (staging_dir != "") {
                    Utils.FileUtils.remove_dir_recursive(staging_dir);
                }
                throw e;
            }
            if (staging_dir != "") {
                Utils.FileUtils.remove_dir_recursive(staging_dir);
            }
            string app_run;
            try {
                app_run = AppImageAssets.ensure_apprun_present(dest_dir);
            } catch (Error e) {
                Utils.FileUtils.remove_dir_recursive(dest_dir);
                throw e;
            }
            Utils.FileUtils.ensure_executable(app_run);
            
            // Check if desktop file Exec points to AppRun, and if so, resolve the actual binary
            string exec_target = app_run;
            try {
                var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-desktop-check-");
                try {
                    var desktop_path = AppImageAssets.extract_desktop_entry(metadata.path, temp_dir);
                    var entry = new DesktopEntry(desktop_path);
                    if (entry.exec != null) {
                        var exec_value = entry.exec;
                        // Check if Exec contains AppRun (without path or with relative path)
                        if ("AppRun" in exec_value) {
                            // Try to parse BIN from AppRun
                            var bin_name = DesktopEntry.parse_bin_from_apprun(app_run);
                            if (bin_name != null && bin_name != "") {
                                var bin_path = Path.build_filename(dest_dir, bin_name);
                                if (File.new_for_path(bin_path).query_exists()) {
                                    Utils.FileUtils.ensure_executable(bin_path);
                                    exec_target = bin_path;
                                    debug("Resolved exec from AppRun BIN=%s to %s", bin_name, exec_target);
                                }
                            }
                        }
                    }
                } finally {
                    Utils.FileUtils.remove_dir_recursive(temp_dir);
                }
            } catch (Error e) {
                warning("Failed to check desktop Exec for AppRun resolution: %s", e.message);
            }
            
            record.installed_path = dest_dir;
            // Capture the source AppImage's SHA-1 as the zsync update baseline.
            // installed_path is now a directory, so the updater cannot recompute
            // this from disk later (see updater probe_zsync_sha1); the source file
            // still exists at this point (it is deleted by the caller afterwards).
            try {
                record.zsync_sha1 = Utils.FileUtils.compute_sha1(metadata.path);
            } catch (Error e) {
                debug("install_extracted: could not compute source SHA-1 baseline: %s", e.message);
            }
                finalize_desktop_and_icon(record, metadata, exec_target, metadata.path, is_upgrade, app_run, install_root);
        }

        /**
         * Derives icon name without path and extension.
         */
        private string derive_icon_name(string? original_icon_name, string fallback_slug) {
            if (original_icon_name == null || original_icon_name == "") {
                return fallback_slug;
            }
            
            var icon_basename = Path.get_basename(original_icon_name);
            if (icon_basename.has_suffix(".svg")) {
                return icon_basename.substring(0, icon_basename.length - 4);
            }
            if (icon_basename.has_suffix(".png")) {
                return icon_basename.substring(0, icon_basename.length - 4);
            }
            return icon_basename;
        }

        /**
         * Detects icon file extension from filename or content.
         */
        private string detect_icon_extension(string icon_path) {
            var icon_file_basename = Path.get_basename(icon_path);
            if (icon_file_basename.has_suffix(".svg")) {
                return ".svg";
            }
            if (icon_file_basename.has_suffix(".png")) {
                return ".png";
            }
            // No extension in filename (e.g., .DirIcon), detect from content
            return Utils.FileUtils.detect_image_extension(icon_path);
        }

        /**
         * Derives fallback StartupWMClass from bundled desktop file name.
         */
        private string derive_fallback_wmclass(string desktop_path) {
            var bundled_desktop_basename = Path.get_basename(desktop_path);
            if (bundled_desktop_basename.has_suffix(".desktop")) {
                return bundled_desktop_basename.substring(0, bundled_desktop_basename.length - 8);
            }
            return bundled_desktop_basename;
        }

        /**
         * Export the icon-theme files the app resolves by name (tray, notification, ...)
         * from the AppImage into the user's hicolor theme.
         *
         * Flatpak automatically exports $FLATPAK_ID* icons to the host theme; an AppImage
         * has no such mechanism, so names like Karere's SNI tray icon
         * ("io.github.tobagin.karere-tray-symbolic") resolve to nothing and the panel
         * shows a missing icon. Mirrors the Flatpak rule - only files named after the
         * app id (or a dotted desktop Icon name) are exported, so a bundled generic icon
         * can never shadow another app's theme entry. Paths are tracked on the record for
         * clean uninstall; existing copies are refreshed in place on upgrade.
         */
        private void install_theme_icons(InstallationRecord record, string assets_path, string temp_root, string desktop_id_hint, string? desktop_icon_name) {
            var prefixes = new Gee.ArrayList<string>();
            var stem = desktop_id_hint;
            if (stem.has_suffix(".desktop")) {
                stem = stem.substring(0, stem.length - 8);
            }
            if (stem.strip() != "") {
                prefixes.add(stem.strip());
            }
            // The desktop entry's own Icon name may differ from the root .desktop
            // filename; when it is id-shaped (dotted) it is the other candidate prefix.
            var icon_name = desktop_icon_name != null ? desktop_icon_name.strip() : "";
            if (icon_name != "" && !icon_name.contains("/") && icon_name.contains(".")
                && !prefixes.contains(icon_name)) {
                prefixes.add(icon_name);
            }
            if (prefixes.size == 0) {
                record.theme_icon_paths = null;
                return;
            }

            string[] matches = AppImageAssets.extract_theme_icons(assets_path, temp_root, prefixes.to_array());
            if (matches.length == 0) {
                record.theme_icon_paths = null;
                return;
            }

            var installed = new Gee.ArrayList<string>();
            bool changed = false;
            foreach (var rel in matches) {
                var source = theme_icon_source(temp_root, rel);
                if (source == null) {
                    continue;
                }
                var dest = Path.build_filename(AppPaths.icons_dir, rel);
                try {
                    if (file_content_differs(source, dest)) {
                        Utils.FileUtils.file_copy(source, dest);
                        changed = true;
                    }
                    installed.add(dest);
                } catch (Error e) {
                    debug("Failed to export theme icon %s: %s", rel, e.message);
                }
            }

            if (changed) {
                update_hicolor_icon_cache();
            }
            record.theme_icon_paths = installed.size > 0 ? installed.to_array() : null;
        }

        /** Locate an extracted theme icon in either AppDir layout. */
        private static string? theme_icon_source(string temp_root, string rel) {
            foreach (var share_root in new string[] { "usr/share", "share" }) {
                var path = Path.build_filename(temp_root, "theme_icons", share_root, "icons", rel);
                if (GLib.FileUtils.test(path, FileTest.IS_REGULAR)) {
                    return path;
                }
            }
            return null;
        }

        /** Whether the destination is missing or holds different bytes than the source. */
        private static bool file_content_differs(string source_path, string dest_path) throws Error {
            if (!GLib.FileUtils.test(dest_path, FileTest.IS_REGULAR)) {
                return true;
            }
            uint8[] source_data;
            uint8[] dest_data;
            GLib.FileUtils.get_data(source_path, out source_data);
            GLib.FileUtils.get_data(dest_path, out dest_data);
            if (source_data.length != dest_data.length) {
                return true;
            }
            for (size_t i = 0; i < source_data.length; i++) {
                if (source_data[i] != dest_data[i]) {
                    return true;
                }
            }
            return false;
        }

        /**
         * Remove the icon-theme files this install exported. Paths another record still
         * tracks are kept: side-by-side copies share these names (the app advertises them
         * by name, so no copy suffix is possible), and unlinking one copy's export would
         * blank the other's tray icon too.
         */
        private void remove_theme_icons(InstallationRecord record) {
            var paths = record.theme_icon_paths;
            record.theme_icon_paths = null;
            if (paths == null || paths.length == 0) {
                return;
            }

            var shared = new Gee.HashSet<string>();
            foreach (var other in registry.list()) {
                if (other.id == record.id) {
                    continue;
                }
                foreach (var path in other.theme_icon_paths ?? new string[0]) {
                    shared.add(path);
                }
            }

            bool removed_any = false;
            foreach (var path in paths) {
                if (shared.contains(path)) {
                    continue;
                }
                try {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) {
                        f.delete(null);
                        removed_any = true;
                    }
                } catch (Error e) {
                    debug("Failed to remove theme icon %s: %s", path, e.message);
                }
            }
            if (removed_any) {
                update_hicolor_icon_cache();
            }
        }

        /** Refresh the hicolor cache after changing files under ~/.local/share/icons. */
        private static void update_hicolor_icon_cache() {
            try {
                Process.spawn_command_line_async("gtk4-update-icon-cache -f -t " +
                    Path.build_filename(AppPaths.icons_dir, "hicolor"));
            } catch (Error e) {
                debug("Icon cache update: %s", e.message);
            }
        }

        private void finalize_desktop_and_icon(InstallationRecord record, AppImageMetadata metadata, string exec_target, string appimage_for_assets, bool is_upgrade, string? app_run_path, string install_root) throws Error {
            string exec_path = exec_target.dup();
            string assets_path = appimage_for_assets.dup();
            string? resolved_entry_exec = null;
            progress("Extracting desktop entry…");
            var temp_dir = Utils.FileUtils.create_temp_dir("appmgr-");
            try {
                var desktop_path = AppImageAssets.extract_desktop_entry(assets_path, temp_dir);
                var icon_path = AppImageAssets.extract_icon(assets_path, temp_dir);
                
                // Try to extract AppRun if not provided (for portable mode)
                string? effective_app_run = app_run_path;
                if (effective_app_run == null) {
                    effective_app_run = AppImageAssets.extract_apprun(assets_path, temp_dir);
                }

                string desktop_name = metadata.display_name;
                string? desktop_version = null;
                bool is_terminal_app = false;
                
                // Use DesktopEntry to parse the file once
                var desktop_entry = new DesktopEntry(desktop_path);
                
                if (desktop_entry.name != null && desktop_entry.name.strip() != "") {
                    desktop_name = desktop_entry.name.strip();
                }
                var desktop_id_hint = Path.get_basename(desktop_path);
                record.appstream_id = AppImageAssets.extract_appstream_id(assets_path, temp_dir, desktop_id_hint, desktop_name);
                record.appstream_checked = true;

                if (desktop_entry.appimage_version != null) {
                    desktop_version = desktop_entry.appimage_version;
                }
                
                // Fall back to metainfo if no version from desktop entry
                if (desktop_version == null) {
                    desktop_version = AppImageAssets.extract_version_from_metainfo(assets_path, temp_dir, desktop_id_hint, desktop_name);
                }
                
                is_terminal_app = desktop_entry.terminal;

                // App description: prefer localized desktop Comment, fall back to matching metainfo summary.
                string? app_description = null;
                if (desktop_entry.comment != null && desktop_entry.comment.strip() != "") {
                    app_description = desktop_entry.comment.strip();
                }
                if (app_description == null) {
                    app_description = AppImageAssets.extract_summary_from_metainfo(assets_path, temp_dir, desktop_id_hint, desktop_name);
                }
                
                record.name = desktop_name;
                record.version = desktop_version;
                record.description = app_description;
                record.is_terminal = is_terminal_app;
                
                // Secondary copies get a frozen "Name N" suffix. Fresh installs compute
                // the next free index; upgrades keep the carried one.
                if (!is_upgrade) {
                    record.copy_index = registry.next_copy_index(desktop_name);
                }
                // naming_name drives slugs/filenames; record.name is the (custom-overridable)
                // display name. original_name is the auto-assigned restore target.
                var naming_name = record.copy_index >= 2
                    ? "%s %d".printf(desktop_name, record.copy_index)
                    : desktop_name;
                var copy_suffix = record.copy_index >= 2 ? "-%d".printf(record.copy_index) : "";

                // Apply history keyed by the suffixed name so secondary copies restore
                // their own customizations instead of inheriting the primary install's.
                // This restores user's custom settings if they uninstalled and are reinstalling.
                // Note: During upgrade, custom values were already copied from old_record in install_sync(),
                // but apply_history won't overwrite existing custom values (only fills in nulls)
                record.name = naming_name;
                registry.apply_history_to_record(record);
                // A custom name restored from history could collide with another
                // install, so fresh copies always start with the assigned name.
                if (!is_upgrade && record.copy_index >= 2) {
                    record.custom_name = null;
                }

                record.original_name = naming_name;
                record.name = record.get_effective_name();

                var slug = slugify_app_name(naming_name);
                if (slug == "") {
                    slug = metadata.sanitized_basename().down();
                }

                var rename_for_extracted = record.mode == InstallMode.EXTRACTED;
                string renamed_path;
                if (rename_for_extracted) {
                    renamed_path = ensure_install_name(record.installed_path, slug, true);
                } else {
                    var app_name = naming_name.strip()
                        .replace("/", " ")
                        .replace("\\", " ")
                        .replace("\n", " ")
                        .replace("\r", " ");
                    if (app_name == "") {
                        app_name = slug;
                    }
                    if (settings.get_boolean("sanitize-filenames-default")) {
                        var sanitized = Utils.FileUtils.sanitize_appimage_filename(app_name);
                        if (sanitized != "") {
                            app_name = sanitized;
                        }
                    }
                    renamed_path = move_portable_to_applications(record.installed_path, app_name, install_root);
                }
                if (renamed_path != record.installed_path) {
                    if (rename_for_extracted) {
                        var exec_basename = Path.get_basename(exec_path);
                        exec_path = Path.build_filename(renamed_path, exec_basename);
                    } else {
                        exec_path = renamed_path;
                        assets_path = renamed_path;
                    }
                    record.installed_path = renamed_path;
                }

                string final_slug;
                if (rename_for_extracted) {
                    final_slug = derive_slug_from_path(record.installed_path, true);
                } else {
                    final_slug = slugify_app_name(Path.get_basename(record.installed_path));
                    if (final_slug == "") {
                        final_slug = slug;
                    }
                }
                
                // Extract original values from desktop entry
                var original_icon_name = desktop_entry.icon;
                var original_keywords = desktop_entry.keywords;
                var original_startup_wm_class = desktop_entry.startup_wm_class;
                var original_homepage = desktop_entry.appimage_homepage;
                var original_update_url = desktop_entry.appimage_update_url;
                
                // Check for zsync update info from .upd_info ELF section
                // If present and is zsync format, store it for delta updates
                string? zsync_info = null;
                if (metadata.update_info != null && metadata.update_info.strip() != "") {
                    var update_info = metadata.update_info.strip();
                    // Check if it's a zsync format (gh-releases-zsync|... or zsync|...)
                    if (update_info.has_prefix("gh-releases-zsync|") || update_info.has_prefix("zsync|")) {
                        zsync_info = update_info;
                        // Use normalized URL as the display update link
                        original_update_url = Updater.normalize_update_url(update_info);
                        // If web page is blank, use the normalized zsync URL as web page
                        if (original_homepage == null || original_homepage.strip() == "") {
                            original_homepage = original_update_url;
                        }
                    } else {
                        // Not zsync, use as regular update URL
                        original_update_url = update_info;
                    }
                }
                
                var exec_value = desktop_entry.exec;
                var parsed_exec = DesktopEntry.parse_exec(exec_value ?? "");
                var original_exec_args = parsed_exec.arguments;
                record.original_env_vars = parsed_exec.env_vars;
                resolved_entry_exec = exec_value != null ? DesktopEntry.resolve_exec_from_desktop(exec_value, effective_app_run) : null;
                
                // Derive icon name without path and extension
                var icon_name_for_desktop = derive_icon_name(original_icon_name, final_slug);
                // Secondary copies need a distinct icon filename so they don't overwrite the primary's.
                if (copy_suffix != "") {
                    icon_name_for_desktop = icon_name_for_desktop + copy_suffix;
                }

                // Derive fallback StartupWMClass from bundled desktop file name (without .desktop extension)
                var fallback_startup_wm_class = derive_fallback_wmclass(desktop_path);
                
                // Check if this is AppManager self-installation
                var is_self_install = (original_startup_wm_class == Core.APPLICATION_ID);
                
                // Install icon to flat ~/.local/share/icons directory
                // Skip for AppManager self-install since install_symbolic_icon() handles it in hicolor theme
                var icon_extension = detect_icon_extension(icon_path);
                var stored_icon = Path.build_filename(AppPaths.icons_dir, "%s%s".printf(icon_name_for_desktop, icon_extension));
                if (!is_self_install) {
                    Utils.FileUtils.file_copy(icon_path, stored_icon);
                }

                // Export the app's icon-theme files so host components can resolve icons
                // by name (tray, notifications, ...) - the Flatpak-style export an AppImage
                // does not get on its own.
                if (!is_self_install) {
                    install_theme_icons(record, assets_path, temp_dir, desktop_id_hint, original_icon_name);
                }
                
                // Store original values temporarily in record for get_effective_* methods to work
                record.original_icon_name = icon_name_for_desktop;
                record.original_keywords = original_keywords;
                record.original_startup_wm_class = original_startup_wm_class ?? fallback_startup_wm_class;
                record.original_commandline_args = original_exec_args;
                record.original_update_link = original_update_url;
                record.original_web_page = original_homepage;
                record.zsync_update_info = zsync_info;  // Store zsync info if present

                // Capture per-action original args from the pristine bundled .desktop so that
                // subsequent rewrites (e.g. from the GUI) have a stable source instead of
                // re-parsing already-modified Exec lines.
                string[]? action_env;
                record.original_action_args = capture_action_args(desktop_entry, out action_env);
                record.original_action_env_vars = action_env;

                if (record.apphub_policy != null && record.apphub_id != null
                    && !record.apphub_policy_customized && !record.is_self_app()) {
                    validate_policy_install(record.mode);
                    AppHubPolicy.parse(record.apphub_id, record.apphub_policy).apply(record);
                }

                // Fresh-install default: opt in to the Standard profile when the user asked
                // for it in Preferences. Special-folder history does not select a profile. Placed after
                // original_startup_wm_class is known, since supports_record() uses it to keep
                // AppManager from sandboxing itself.
                if (!is_upgrade
                    && record.sandbox_profile == null
                    && !record.apphub_policy_customized
                    && AppPaths.sandbox_available
                    && SandboxConfig.supports_record(record)
                    && settings.get_boolean("default-sandbox-enabled")) {
                    SandboxConfig.apply_preset(record, SANDBOX_PROFILE_STANDARD);
                }
                // Carried active settings may be unsupported after a mode change or
                // self-installation. Drop the profile rather than emit an
                // Exec line pointing at a sandbox that will never work.
                if (record.sandbox_enabled() && !SandboxConfig.supports_record(record)) {
                    record.sandbox_profile = null;
                }

                // For fresh install with history (reinstall), use effective values (considers CLEARED_VALUE)
                var effective_icon = record.get_effective_icon_name() ?? icon_name_for_desktop;
                var effective_keywords = record.get_effective_keywords();
                var effective_wmclass = record.get_effective_startup_wm_class();
                var effective_args = record.get_effective_commandline_args();
                var effective_update_link = record.get_effective_update_link();
                var effective_web_page = record.get_effective_web_page();
                var effective_name = record.get_effective_name();

                var desktop_contents = rewrite_desktop(desktop_path, exec_path, record, is_terminal_app, final_slug, is_upgrade, effective_icon, effective_keywords, effective_wmclass, effective_args, effective_update_link, effective_web_page, effective_name);
                
                // Preserve original bundled desktop filename for proper desktop integration
                var desktop_filename = Path.get_basename(desktop_path);
                // Secondary copies get a suffixed (and guaranteed-unique) desktop file so they
                // don't overwrite the primary's entry.
                if (copy_suffix != "") {
                    var stem = desktop_filename.has_suffix(".desktop")
                        ? desktop_filename.substring(0, desktop_filename.length - 8)
                        : desktop_filename;
                    desktop_filename = "%s%s.desktop".printf(stem, copy_suffix);
                }
                var desktop_destination = Path.build_filename(AppPaths.desktop_dir, desktop_filename);
                if (copy_suffix != "") {
                    desktop_destination = Utils.FileUtils.unique_path(desktop_destination);
                }
                Utils.FileUtils.ensure_parent(desktop_destination);
                // The manifest's own-names come from desktop_file, and the manifest must
                // exist before an Exec line pointing at sandbox-run does.
                record.desktop_file = desktop_destination;
                if (record.sandbox_enabled() && (has_portable_home(record) || has_portable_config(record))) {
                    migrate_portable_to_sandbox(record, false);
                }
                if (!SandboxConfig.sync_manifest(record, registry.list())) {
                    throw new InstallerError.UNKNOWN(_("Unable to write the sandbox manifest."));
                }

                // Always write desktop file - custom values from JSON are applied via get_effective_*()
                // The old desktop file is deleted during uninstall, so we must write the new one
                if (!GLib.FileUtils.set_contents(desktop_destination, desktop_contents)) {
                    throw new InstallerError.UNKNOWN("Unable to write desktop file");
                }
                write_autostart_entry(record, exec_path);
                // For self-install, use hicolor path; otherwise use flat icons directory
                record.icon_path = is_self_install ? AppPaths.main_icon_path : stored_icon;
                
                if (resolved_entry_exec != null && resolved_entry_exec.strip() != "") {
                    var stored_exec = resolved_entry_exec.strip();
                    if (record.mode == InstallMode.EXTRACTED && record.installed_path.strip() != "") {
                        stored_exec = DesktopEntry.relativize_exec_to_installed(stored_exec, record.installed_path);
                    }
                    record.entry_exec = stored_exec;
                }

                // original_* values were already set above before get_effective_* calls

                // Create symlink for all applications by default (improves compatibility)
                progress("Creating symlink for application…");
                var symlink_name = final_slug;

                if (resolved_entry_exec != null && resolved_entry_exec.strip() != "") {
                    symlink_name = Path.get_basename(resolved_entry_exec.strip());
                }

                if (record.is_self_app()) {
                    symlink_name = "app-manager";
                }
                // Sub-entries of multi-component AppImages reference this name without the
                // side-by-side copy suffix, so keep the un-suffixed form for comparison.
                var primary_bin = symlink_name;
                // Secondary copies need a distinct symlink so they don't overwrite the primary's.
                if (copy_suffix != "") {
                    symlink_name = symlink_name + copy_suffix;
                }
                // Default is to create a bin symlink. Terminal apps always do.
                // Otherwise the user can opt out via custom_add_to_path = "false".
                if (record.is_terminal || record.custom_add_to_path != "false") {
                    record.bin_symlink = create_bin_launcher(record, exec_path, symlink_name);
                } else {
                    record.bin_symlink = null;
                }

                // Install additional desktop entries from usr/share/applications/ (issue #106).
                // No-op when AppImage has no sub-entries; never aborts the install on failure.
                install_extra_desktop_entries(record, exec_path, assets_path, temp_dir, primary_bin, desktop_path);
            } finally {
                Utils.FileUtils.remove_dir_recursive(temp_dir);
            }
        }
        public void uninstall(InstallationRecord record, bool permanently = false, bool preserve_portable = false) throws Error {
            uninstall_sync(record, permanently, preserve_portable);
        }

        private void uninstall_sync(InstallationRecord record, bool permanently, bool preserve_portable = false) throws Error {
            try {
                // Mark as in-flight and unregister FIRST to prevent reconcile race conditions
                // This ensures the record is removed from registry before the file is deleted,
                // so DirectoryMonitor won't see it as orphaned during the deletion.
                registry.mark_in_flight(record.id);
                registry.unregister(record.id);
                
                // Now safely delete the files
                var installed_file = File.new_for_path(record.installed_path);
                if (installed_file.query_exists()) {
                    if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                        Utils.FileUtils.remove_dir_recursive(record.installed_path);
                    } else if (permanently) {
                        installed_file.delete(null);
                    } else {
                        try {
                            installed_file.trash(null);
                        } catch (Error trash_err) {
                            // Re-register the record so it's not lost when user is prompted
                            registry.register(record);
                            throw new InstallerError.UNINSTALL_FAILED("TRASH_FAILED: %s".printf(trash_err.message));
                        }
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                // Drop the link that showed this app in the main installation
                // folder, so an app stored on another path leaves nothing behind
                // in the regular location.
                AppPaths.remove_installation_symlink(
                    record.symlink_path ?? AppPaths.symlink_path_for(record.installed_path),
                    record.installed_path);
                remove_autostart_entry(record);
                // Only unlink what we created
                if (record.bin_symlink != null && bin_launcher_is_ours(record.bin_symlink, record)) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }

                // Extra desktop entries / icons / symlinks installed for multi-component apps (issue #106)
                foreach (var path in record.extra_desktop_files ?? new string[0]) {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                }
                foreach (var path in record.extra_icon_paths ?? new string[0]) {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                }
                foreach (var path in record.extra_bin_symlinks ?? new string[0]) {
                    if (bin_symlink_is_ours(path, record.installed_path)) File.new_for_path(path).delete(null);
                }

                // Icon-theme files exported at install (names the app resolves at
                // runtime: tray, notifications, ...)
                remove_theme_icons(record);

                // Remove AppImage portable folders (.home/.config) unless the caller is
                // upgrading a portable install and wants to keep the user data.
                // The sandboxed home holds the same kind of user data, so it follows
                // the same rule.
                if (!preserve_portable) {
                    remove_portable_folders(record, !permanently);
                    remove_sandbox_home(record, !permanently);
                }
                SandboxManifest.remove(record.id);

                // Remove symbolic icon when uninstalling AppManager itself
                if (record.is_self_app()) {
                    uninstall_symbolic_icon();
                }
                
                // Update MIME database after removing desktop file
                update_desktop_database();
            } catch (Error e) {
                // Clear in-flight flag on error
                registry.clear_in_flight(record.id);
                throw new InstallerError.UNINSTALL_FAILED(e.message);
            }
        }

        private void cleanup_failed_installation(InstallationRecord record) {
            try {
                // Only clean up installed_path if it differs from source_path
                // (i.e., if a move/copy actually happened before failure)
                if (record.installed_path != null && record.installed_path != record.source_path) {
                    var installed_file = File.new_for_path(record.installed_path);
                    if (installed_file.query_exists()) {
                        if (installed_file.query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                            Utils.FileUtils.remove_dir_recursive(record.installed_path);
                        } else {
                            installed_file.delete(null);
                        }
                    }
                }
                if (record.desktop_file != null && File.new_for_path(record.desktop_file).query_exists()) {
                    File.new_for_path(record.desktop_file).delete(null);
                }
                if (record.icon_path != null && File.new_for_path(record.icon_path).query_exists()) {
                    File.new_for_path(record.icon_path).delete(null);
                }
                AppPaths.remove_installation_symlink(
                    record.symlink_path ?? AppPaths.symlink_path_for(record.installed_path),
                    record.installed_path);
                if (record.bin_symlink != null && bin_launcher_is_ours(record.bin_symlink, record)) {
                    File.new_for_path(record.bin_symlink).delete(null);
                }
                foreach (var path in record.extra_desktop_files ?? new string[0]) {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                }
                foreach (var path in record.extra_icon_paths ?? new string[0]) {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                }
                foreach (var path in record.extra_bin_symlinks ?? new string[0]) {
                    if (bin_symlink_is_ours(path, record.installed_path)) File.new_for_path(path).delete(null);
                }
                remove_theme_icons(record);
            } catch (Error e) {
                warning("Failed to cleanup after installation error: %s", e.message);
            }
        }

        private string[]? capture_action_args(DesktopEntry entry, out string[]? env_vars) {
            var keyfile = entry.get_key_file();
            var actions_str = entry.actions ?? "";
            var captured = new Gee.ArrayList<string>();
            var captured_env = new Gee.ArrayList<string>();
            foreach (var part in actions_str.split(";")) {
                var name = part.strip();
                if (name == "" || name == "Uninstall") continue;
                var group = "Desktop Action %s".printf(name);
                try {
                    if (!keyfile.has_group(group) || !keyfile.has_key(group, "Exec")) continue;
                    var parsed = DesktopEntry.parse_exec(keyfile.get_string(group, "Exec"));
                    captured.add("%s=%s".printf(name, parsed.arguments ?? ""));
                    foreach (var variable in parsed.env_vars) captured_env.add("%s=%s".printf(name, variable));
                } catch (Error e) {
                    debug("capture_action_args %s: %s", group, e.message);
                }
            }
            env_vars = captured_env.to_array();
            return captured.size > 0 ? captured.to_array() : null;
        }

        /**
         * The Exec= tokens that launch `exec_target`. For a sandboxed record this is
         * AppManager re-entered as the sandbox launcher, ending in the "--" separator
         * so whatever the caller appends belongs to the app rather than to us.
         *
         * Every Exec line in the entry — primary, each desktop action, each sub-entry —
         * goes through here, which is what makes a permission change rewrite one
         * manifest instead of every line.
         */
        private string launch_tokens(InstallationRecord record, string exec_target, string[]? env_vars = null) {
            if (!record.sandbox_enabled()) {
                return "\"%s\"".printf(exec_target);
            }
            // Same prefix used for the Uninstall action: how to invoke AppManager itself.
            var parts = new StringBuilder();
            foreach (var token in uninstall_prefix) {
                if (parts.len > 0) {
                    parts.append(" ");
                }
                parts.append(Utils.FileUtils.quote_exec_token(token));
            }
            // Record ids are checksums (optionally "-N"), so they need no quoting.
            parts.append(" %s --id=%s".printf(SANDBOX_RUN_VERB, record.id));
            parts.append(" \"--target=%s\"".printf(Utils.FileUtils.escape_exec_arg(exec_target)));
            foreach (var variable in env_vars ?? new string[0]) {
                parts.append(" \"%s\"".printf(escape_env_exec_token("--env=" + variable)));
            }
            parts.append(" --");
            return parts.str;
        }

        private string build_env_prefix(string[]? env_vars) {
            if (env_vars == null || env_vars.length == 0) {
                return "";
            }
            // Use an absolute helper path: an old installation may have created ~/.local/bin/env.
            var env_builder = new StringBuilder("/usr/bin/env -- ");
            foreach (var env_var in env_vars) {
                if (env_var != null && env_var.strip() != "") {
                    var eq_pos = env_var.index_of_char('=');
                    if (eq_pos >= 0) {
                        env_builder.append("\"%s\" ".printf(escape_env_exec_token(env_var)));
                    }
                }
            }
            return env_builder.str;
        }

        private static string escape_env_exec_token(string token) {
            return token.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("$", "\\$").replace("`", "\\`").replace("%", "%%");
        }

        private static string[] entry_env_vars(string[]? captured, string entry_name) {
            var variables = new Gee.ArrayList<string>();
            var prefix = entry_name + "=";
            foreach (var pair in captured ?? new string[0]) {
                if (pair.has_prefix(prefix)) variables.add(pair.substring(prefix.length));
            }
            return variables.to_array();
        }

        // The portion of custom_commandline_args the user added beyond the root entry's default
        // args (original_commandline_args). The root's defaults (e.g. %F) belong only to the
        // primary Exec; appending them to entries that have their own field codes would duplicate
        // them. Root default tokens are removed wherever they appear (not just as a prefix), so
        // inserting custom args before or after %F yields the same result. Returns "" when the
        // user set no custom args (or cleared them).
        private string user_added_commandline_args(InstallationRecord record) {
            if (record.custom_commandline_args == null
                || record.custom_commandline_args == CLEARED_VALUE
                || record.custom_commandline_args.strip() == "") {
                return "";
            }
            var custom = record.custom_commandline_args.strip();
            var original = (record.original_commandline_args ?? "").strip();
            if (original == "") {
                return custom;
            }
            var defaults = new Gee.HashSet<string>();
            foreach (var tok in original.split(" ")) {
                var t = tok.strip();
                if (t != "") defaults.add(t);
            }
            var kept = new StringBuilder();
            foreach (var tok in custom.split(" ")) {
                var t = tok.strip();
                if (t == "" || defaults.contains(t)) continue;
                if (kept.len > 0) kept.append(" ");
                kept.append(t);
            }
            return kept.str;
        }

        // The primary Exec line. Shared with the autostart entry so a login start matches
        // a menu start (env vars, sandbox launcher, args).
        private string build_exec_line(InstallationRecord record, string exec_target, string args) {
            var env_vars = record.get_effective_env_vars();
            var env_prefix = record.sandbox_enabled() ? "" : build_env_prefix(env_vars);
            var launcher = launch_tokens(record, exec_target, env_vars);
            if (args.strip() != "") {
                return "%s%s %s".printf(env_prefix, launcher, args);
            }
            return "%s%s".printf(env_prefix, launcher);
        }

        private string rewrite_desktop(string desktop_path, string exec_target, InstallationRecord record, bool is_terminal, string slug, bool is_upgrade, string? effective_icon_name, string? effective_keywords, string? effective_startup_wm_class, string? effective_commandline_args, string? effective_update_link, string? effective_web_page, string? effective_name = null) throws Error {
            var entry = new DesktopEntry(desktop_path);

            // Update Name (secondary-copy suffix or user-customized app name). Leaving it
            // null keeps the bundled .desktop Name untouched.
            if (effective_name != null && effective_name.strip() != "") {
                entry.name = effective_name.strip();
            }

            // Update Exec with optional environment variables
            entry.exec = build_exec_line(record, exec_target, effective_commandline_args ?? "");

            // Action Exec lines: same shape as main Exec, but each action keeps its own
            // intrinsic args (--new-window, --screenshot, ...) instead of effective_commandline_args.
            // Pristine action args come from record.original_action_args (captured at install time);
            // re-parsing the current Exec would compound corruption across repeated rewrites.
            // Only the user-added args (not the root default %F) are appended, so an action's own
            // field codes aren't duplicated by the root's default.
            var extra_user_args = user_added_commandline_args(record);
            var keyfile = entry.get_key_file();
            if (record.original_action_args != null) {
                foreach (var pair in record.original_action_args) {
                    var eq = pair.index_of_char('=');
                    if (eq < 0) continue;
                    var action_name = pair.substring(0, eq);
                    var preserved = pair.substring(eq + 1);
                    var group = "Desktop Action %s".printf(action_name);
                    if (!keyfile.has_group(group)) continue;
                    var trail = (preserved + " " + extra_user_args).strip();
                    var action_env = record.get_effective_env_vars(entry_env_vars(record.original_action_env_vars, action_name));
                    var action_env_prefix = record.sandbox_enabled() ? "" : build_env_prefix(action_env);
                    var action_launcher = launch_tokens(record, exec_target, action_env);
                    var line = trail == ""
                        ? "%s%s".printf(action_env_prefix, action_launcher)
                        : "%s%s %s".printf(action_env_prefix, action_launcher, trail);
                    keyfile.set_string(group, "Exec", line);
                }
            }
            
            // Update Icon
            entry.icon = (effective_icon_name != null && effective_icon_name.strip() != "") ? effective_icon_name : null;
            
            // Update StartupWMClass
            entry.startup_wm_class = (effective_startup_wm_class != null && effective_startup_wm_class.strip() != "") ? effective_startup_wm_class : null;
            
            // Update Keywords
            entry.keywords = (effective_keywords != null && effective_keywords.strip() != "") ? effective_keywords : null;
            
            // Update NoDisplay: terminal apps are always hidden; otherwise honor user override
            // (custom_no_display) or fall back to whatever the bundled .desktop ships with.
            if (is_terminal) {
                entry.no_display = true;
            } else if (record.custom_no_display != null) {
                entry.no_display = (record.custom_no_display == "true");
            }
            // else: leave entry.no_display as loaded from the bundled .desktop file
            
            // Update X-AppImage fields
            entry.appimage_homepage = (effective_web_page != null && effective_web_page.strip() != "") ? effective_web_page : null;
            entry.appimage_update_url = (effective_update_link != null && effective_update_link.strip() != "") ? effective_update_link : null;
            
            // Ensure Uninstall action exists
            var actions_str = entry.actions ?? "";
            var actions = new Gee.ArrayList<string>();
            foreach (var part in actions_str.split(";")) {
                var action = part.strip();
                if (action != "" && action != "Uninstall") {
                    actions.add(action);
                }
            }
            actions.add("Uninstall");
            
            var action_builder = new StringBuilder();
            foreach (var action_name in actions) {
                action_builder.append(action_name);
                action_builder.append(";");
            }
            entry.actions = action_builder.str;
            
            // Remove TryExec
            entry.remove_key("TryExec");
            
            // Disable DBusActivatable - AppImages don't have D-Bus service files,
            // so we must force the launcher to use Exec= instead of D-Bus activation
            entry.remove_key("DBusActivatable");
            
            // Add Uninstall action block
            // Check if this is a self-install (AppManager installing itself)
            var is_self_install = (entry.startup_wm_class == Core.APPLICATION_ID);
            var uninstall_exec = build_uninstall_exec(record.installed_path, is_self_install);
            var home = Environment.get_home_dir();
            var is_trashable = record.installed_path.has_prefix(home + "/");
            var uninstall_label = is_trashable ? "Move to Trash" : "Delete Permanently";
            var uninstall_icon = is_trashable ? "user-trash" : "edit-delete";
            var locale_code = Core.get_locale_code();
            var localized_label = is_trashable ? _("Move to Trash") : _("Delete Permanently");
            entry.set_action_group("Uninstall", uninstall_label, uninstall_exec, uninstall_icon, locale_code, localized_label);
            
            return entry.to_data();
        }

        /**
         * Rewrites a sub-desktop file (extracted from usr/share/applications/) to:
         *  - replace Exec with the per-component bin symlink + preserved original args
         *  - replace Icon with the resolved icon name (already extracted by caller)
         *  - inject the same Uninstall action as the primary entry (tears down whole app)
         *  - strip TryExec / DBusActivatable
         * Other fields (StartupWMClass, Categories, MimeType, NoDisplay, localized Name[xx])
         * are intentionally left untouched - these are what distinguish each component.
         */
        private string rewrite_sub_desktop(string sub_desktop_path, string sub_binary_symlink_path, string? sub_icon_name, string pristine_args, InstallationRecord record, string[]? bundled_env = null) throws Error {
            var entry = new DesktopEntry(sub_desktop_path);

            // Apply the same custom env vars and command-line args as the primary entry.
            // Each component keeps its own pristine args (captured at install in original_sub_args).
            // Only the args the user ADDED beyond the root default are appended - appending the
            // whole custom string would drag the root's default field codes (e.g. %F) into the
            // component's own args. Using pristine_args (not the current Exec) avoids compounding.
            var env_vars = record.get_effective_env_vars(bundled_env);
            var env_prefix = record.sandbox_enabled() ? "" : build_env_prefix(env_vars);
            var extra_user_args = user_added_commandline_args(record);
            var args = (pristine_args + " " + extra_user_args).strip();
            // The target stays the component's ~/.local/bin symlink even when sandboxed:
            // the launcher mounts the AppImage the link resolves to, but passes the
            // unresolved spelling on as ARGV0, which is how the AppImage runtime picks
            // the component to start.
            var launcher = launch_tokens(record, sub_binary_symlink_path, env_vars);
            string exec_line;
            if (args != "") {
                exec_line = "%s%s %s".printf(env_prefix, launcher, args);
            } else {
                exec_line = "%s%s".printf(env_prefix, launcher);
            }
            entry.exec = exec_line;

            if (sub_icon_name != null && sub_icon_name.strip() != "") {
                entry.icon = sub_icon_name;
            }

            entry.remove_key("TryExec");
            entry.remove_key("DBusActivatable");

            // Inject Uninstall action that targets the whole installed app
            var actions_str = entry.actions ?? "";
            var actions = new Gee.ArrayList<string>();
            foreach (var part in actions_str.split(";")) {
                var action = part.strip();
                if (action != "" && action != "Uninstall") {
                    actions.add(action);
                }
            }
            actions.add("Uninstall");
            var action_builder = new StringBuilder();
            foreach (var action_name in actions) {
                action_builder.append(action_name);
                action_builder.append(";");
            }
            entry.actions = action_builder.str;

            var is_self_install = (entry.startup_wm_class == Core.APPLICATION_ID);
            var uninstall_exec = build_uninstall_exec(record.installed_path, is_self_install);
            var home = Environment.get_home_dir();
            var is_trashable = record.installed_path.has_prefix(home + "/");
            var uninstall_label = is_trashable ? "Move to Trash" : "Delete Permanently";
            var uninstall_icon = is_trashable ? "user-trash" : "edit-delete";
            var locale_code = Core.get_locale_code();
            var localized_label = is_trashable ? _("Move to Trash") : _("Delete Permanently");
            entry.set_action_group("Uninstall", uninstall_label, uninstall_exec, uninstall_icon, locale_code, localized_label);

            return entry.to_data();
        }

        /**
         * Removes previously-installed extra desktop entries / icons / symlinks for this record.
         * Called before re-installing extras on upgrade so stale paths don't linger.
         * The primary entry's desktop file and bin symlink are skipped: sub-entries that only
         * re-point the primary command list them as their own target, and by the time this runs
         * the primary pass has already (re)created both.
         */
        private void remove_extra_entries(InstallationRecord record) {
            foreach (var path in record.extra_desktop_files ?? new string[0]) {
                if (path == record.desktop_file) continue;
                try {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                } catch (Error e) {
                    debug("Failed to remove extra desktop %s: %s", path, e.message);
                }
            }
            foreach (var path in record.extra_icon_paths ?? new string[0]) {
                if (path == record.icon_path) continue;
                try {
                    var f = File.new_for_path(path);
                    if (f.query_exists()) f.delete(null);
                } catch (Error e) {
                    debug("Failed to remove extra icon %s: %s", path, e.message);
                }
            }
            foreach (var path in record.extra_bin_symlinks ?? new string[0]) {
                if (path == record.bin_symlink) continue;
                try {
                    if (bin_symlink_is_ours(path, record.installed_path)) File.new_for_path(path).delete(null);
                } catch (Error e) {
                    debug("Failed to remove extra bin symlink %s: %s", path, e.message);
                }
            }
            record.extra_desktop_files = null;
            record.extra_icon_paths = null;
            record.extra_bin_symlinks = null;
        }

        /**
         * Install the .desktop entries from usr/share/applications/ inside the AppImage that the
         * AppImage actually ships a command for (issue #106 - multi-component AppImages such as
         * office suites, which present several separate menu entries).
         *
         * Bundling a whole toolkit or runtime commonly drags its background-service entries along
         * too (helper daemons, settings modules, protocol helpers). Those point at binaries the
         * AppImage keeps under libexec, or does not contain at all, so requiring the Exec binary to
         * be a real command keeps them out of $PATH and the menu, as does requiring a hidden entry
         * to carry MimeType associations that justify installing it at all. Each accepted entry gets a
         * ~/.local/bin/<name> symlink to the AppImage (multi-call dispatch via argv[0]); entries
         * that share a binary share the one command.
         *
         * The root .desktop the primary pass installed is normally a copy of one of these payload
         * entries, so it turns up here too and must not be installed twice. Its filename is no help:
         * the AppDir spec lets it be anything (MKVToolNix ships mkvtoolnix-gui.desktop in the root
         * and org.bunkus.mkvtoolnix-gui.desktop in the payload), so it is matched by content.
         *
         * Tracks all created paths on the record for clean uninstall. No-op when no extras present.
         */
        private void install_extra_desktop_entries(InstallationRecord record, string exec_path, string assets_path, string temp_root, string primary_bin, string primary_desktop_path) {
            string[] extras;
            try {
                extras = AppImageAssets.extract_extra_desktop_entries(assets_path, temp_root);
            } catch (Error e) {
                warning("Failed to extract extra desktop entries: %s", e.message);
                return;
            }
            if (extras.length == 0) {
                return;
            }

            // Signature of the bundled root entry, before rewrite_desktop() touched it.
            var primary_signature = DesktopEntry.entry_signature(primary_desktop_path);

            // Clear any prior extras (upgrade path) - files on disk are stale.
            remove_extra_entries(record);

            var installed_desktops = new Gee.ArrayList<string>();
            var installed_icons    = new Gee.ArrayList<string>();
            var installed_symlinks = new Gee.ArrayList<string>();
            var sub_args           = new Gee.ArrayList<string>();
            var sub_env            = new Gee.ArrayList<string>();

            // Sub-binary -> the Exec target its entries point at, "" when the AppImage ships no such
            // command. Memoised so a binary shared by several entries is probed and symlinked once.
            // The primary command always exists, so it never needs probing.
            var targets = new Gee.HashMap<string, string>();
            // Bypass the primary wrapper: sandbox-run would recurse, and an env wrapper
            // would overwrite a sub-entry's own variables with the root entry's defaults.
            targets.set(primary_bin, (record.sandbox_enabled() || record.get_effective_env_vars().length > 0)
                ? exec_path
                : (record.bin_symlink ?? exec_path));

            foreach (var sub_path in extras) {
                try {
                    var sub_entry = new DesktopEntry(sub_path);
                    var sub_exec = sub_entry.exec ?? "";

                    // NoDisplay hides the entry from the menu, leaving association as its only
                    // purpose; with no MimeType it can be neither launched nor matched, and would
                    // just add a stray command to $PATH. This is how a bundled dependency's own
                    // entry leaks in (Inkscape ships python3.8, ONLYOFFICE ships keditbookmarks).
                    if (sub_entry.no_display && (sub_entry.mime_type == null || sub_entry.mime_type.strip() == "")) {
                        debug("Skipping sub-desktop %s: hidden and provides no associations", sub_path);
                        continue;
                    }

                    var parsed_exec = DesktopEntry.parse_exec(sub_exec);
                    var base_token = parsed_exec.command;
                    if (base_token == null || base_token.strip() == "") {
                        debug("Skipping sub-desktop %s: empty Exec", sub_path);
                        continue;
                    }
                    var sub_bin = Path.get_basename(DesktopEntry.strip_appdir_prefix(base_token));
                    if (sub_bin == "" || DesktopEntry.is_apprun_token(sub_bin)) {
                        debug("Skipping sub-desktop %s: unusable binary token %s", sub_path, base_token);
                        continue;
                    }
                    var dest = Path.build_filename(AppPaths.desktop_dir, Path.get_basename(sub_path));
                    if (dest == record.desktop_file) {
                        // The AppImage's root .desktop is a symlink into usr/share/applications/, so
                        // it shows up here too - the primary pass already installed it.
                        continue;
                    }
                    if (primary_signature != null && DesktopEntry.entry_signature(sub_path) == primary_signature) {
                        // Same launcher as the root entry, only under a different filename.
                        debug("Skipping sub-desktop %s: duplicate of the root entry", sub_path);
                        continue;
                    }

                    if (!targets.has_key(sub_bin)) {
                        string? sym = null;
                        if (AppImageAssets.has_bundled_binary(assets_path, temp_root, sub_bin)) {
                            sym = create_bin_symlink(exec_path, sub_bin, record.installed_path, null);
                        }
                        targets.set(sub_bin, sym ?? "");
                    }
                    var target = targets.get(sub_bin);
                    if (target == "") {
                        debug("Skipping sub-desktop %s: %s is not a command in the AppImage", sub_path, sub_bin);
                        continue;
                    }

                    string? installed_icon_path = null;
                    string? icon_name_for_desktop = sub_entry.icon;
                    if (icon_name_for_desktop != null && icon_name_for_desktop.strip() != "") {
                        var extracted_icon = AppImageAssets.extract_named_icon(assets_path, temp_root, icon_name_for_desktop);
                        if (extracted_icon != null) {
                            var ext = detect_icon_extension(extracted_icon);
                            var stored = Path.build_filename(AppPaths.icons_dir, "%s%s".printf(icon_name_for_desktop, ext));
                            try {
                                Utils.FileUtils.ensure_parent(stored);
                                Utils.FileUtils.file_copy(extracted_icon, stored);
                                installed_icon_path = stored;
                            } catch (Error e) {
                                debug("Failed to copy sub-icon %s: %s", extracted_icon, e.message);
                            }
                        }
                    }

                    var pristine_args = parsed_exec.arguments ?? "";
                    var contents = rewrite_sub_desktop(sub_path, target, icon_name_for_desktop, pristine_args, record, parsed_exec.env_vars);
                    Utils.FileUtils.ensure_parent(dest);
                    if (!GLib.FileUtils.set_contents(dest, contents)) {
                        warning("Failed to write sub-desktop %s", dest);
                        // Roll back this entry's icon, and the command too when no entry uses it yet
                        // (dropping it from the memo lets a sibling recreate it).
                        if (installed_icon_path != null) {
                            try {
                                var icon_file = File.new_for_path(installed_icon_path);
                                if (icon_file.query_exists()) icon_file.delete(null);
                            } catch (Error e) {
                                debug("Cleanup of failed sub-icon %s: %s", installed_icon_path, e.message);
                            }
                        }
                        if (target != record.bin_symlink && !installed_symlinks.contains(target)) {
                            try {
                                var sym_file = File.new_for_path(target);
                                if (sym_file.query_exists()) sym_file.delete(null);
                            } catch (Error e) {
                                debug("Cleanup of failed sub-symlink %s: %s", target, e.message);
                            }
                            targets.unset(sub_bin);
                        }
                        continue;
                    }

                    installed_desktops.add(dest);
                    installed_symlinks.add(target);
                    sub_args.add("%s=%s".printf(Path.get_basename(dest), pristine_args));
                    foreach (var variable in parsed_exec.env_vars) sub_env.add("%s=%s".printf(Path.get_basename(dest), variable));
                    if (installed_icon_path != null) {
                        installed_icons.add(installed_icon_path);
                    }
                } catch (Error e) {
                    warning("Failed to process sub-desktop %s: %s", sub_path, e.message);
                }
            }

            record.extra_desktop_files = installed_desktops.size > 0 ? installed_desktops.to_array() : null;
            record.extra_icon_paths    = installed_icons.size    > 0 ? installed_icons.to_array()    : null;
            record.extra_bin_symlinks  = installed_symlinks.size > 0 ? installed_symlinks.to_array() : null;
            record.original_sub_args   = sub_args.size           > 0 ? sub_args.to_array()           : null;
            record.original_sub_env_vars = sub_env.to_array();
        }

        private string build_uninstall_exec(string installed_path, bool is_self_install) {
            var parts = new Gee.ArrayList<string>();
            
            if (is_self_install) {
                // For self-install, use the installed path as the executable
                // This ensures the uninstall action uses the destination location
                parts.add(Utils.FileUtils.quote_exec_token(installed_path));
            } else {
                // For other apps, use the normal uninstall prefix (AppManager executable)
                foreach (var token in uninstall_prefix) {
                    parts.add(Utils.FileUtils.quote_exec_token(token));
                }
            }
            
            parts.add("uninstall");
            parts.add("\"%s\"".printf(Utils.FileUtils.escape_exec_arg(installed_path)));
            var builder = new StringBuilder();
            for (int i = 0; i < parts.size; i++) {
                if (i > 0) {
                    builder.append(" ");
                }
                builder.append(parts.get(i));
            }
            return builder.str;
        }


        private string slugify_app_name(string name) {
            var normalized = name.strip().down();
            var builder = new StringBuilder();
            bool last_was_separator = false;
            for (int i = 0; i < normalized.length; i++) {
                char ch = normalized[i];
                if (ch == '\0') {
                    break;
                }
                if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
                    builder.append_c(ch);
                    last_was_separator = false;
                    continue;
                }
                if (!last_was_separator && builder.len > 0) {
                    builder.append_c('_');
                }
                last_was_separator = true;
            }
            return builder.len > 0 ? builder.str : "";
        }

        private string ensure_install_name(string current_path, string slug, bool is_extracted) throws Error {
            if (slug == "") {
                return current_path;
            }
            var parent = Path.get_dirname(current_path);
            string desired;
            if (is_extracted) {
                desired = Path.build_filename(parent, slug);
            } else {
                desired = Path.build_filename(parent, slug + get_path_extension(current_path));
            }

            if (desired == current_path) {
                return current_path;
            }

            if (File.new_for_path(desired).query_exists()) {
                var current_slug = derive_slug_from_path(current_path, is_extracted);
                if (current_slug != slug) {
                    return current_path;
                }
            }

            var final_target = Utils.FileUtils.unique_path(desired);
            if (final_target == current_path) {
                return current_path;
            }
            var source = File.new_for_path(current_path);
            var dest = File.new_for_path(final_target);
            source.move(dest, FileCopyFlags.NONE, null, null);
            return final_target;
        }

        private string move_portable_to_applications(string source_path, string app_name, string install_root) throws Error {
            var desired = Path.build_filename(install_root, app_name);
            var final_path = Utils.FileUtils.unique_path(desired);
            var source = File.new_for_path(source_path);
            var dest = File.new_for_path(final_path);
            source.move(dest, FileCopyFlags.NONE, null, null);
            Utils.FileUtils.ensure_executable(final_path);
            return final_path;
        }

        private string get_path_extension(string path) {
            var base_name = Path.get_basename(path);
            var dot_index = base_name.last_index_of_char('.');
            return dot_index >= 0 ? base_name.substring(dot_index) : "";
        }

        public string derive_slug_from_path(string path, bool is_extracted) {
            var base_name = Path.get_basename(path);
            if (!is_extracted) {
                var dot_index = base_name.last_index_of_char('.');
                if (dot_index > 0) {
                    base_name = base_name.substring(0, dot_index);
                }
            }
            return base_name.down();
        }

        private string[] resolve_uninstall_prefix() {
            var prefix = new Gee.ArrayList<string>();
            if (is_flatpak_sandbox()) {
                var flatpak_id = flatpak_app_id();
                if (flatpak_id != null) {
                    var trimmed = flatpak_id.strip();
                    if (trimmed != "") {
                        prefix.add("flatpak");
                        prefix.add("run");
                        prefix.add(trimmed);
                        return list_to_string_array(prefix);
                    }
                }
            }
            string? resolved = current_executable_path();
            if (resolved == null || resolved.strip() == "") {
                resolved = Environment.find_program_in_path("app-manager");
            }
            if (resolved == null || resolved.strip() == "") {
                resolved = "app-manager";
            }
            prefix.add(resolved);
            return list_to_string_array(prefix);
        }

        private string[] list_to_string_array(Gee.ArrayList<string> list) {
            var result = new string[list.size];
            for (int i = 0; i < list.size; i++) {
                result[i] = list.get(i);
            }
            return result;
        }

        private bool is_flatpak_sandbox() {
            return GLib.FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }

        private string? flatpak_app_id() {
            var env_id = Environment.get_variable("FLATPAK_ID");
            if (env_id != null && env_id.strip() != "") {
                return env_id;
            }
            try {
                var info = new KeyFile();
                info.load_from_file("/.flatpak-info", KeyFileFlags.NONE);
                if (info.has_key("Application", "name")) {
                    return info.get_string("Application", "name");
                }
            } catch (Error e) {
                warning("Failed to read flatpak info: %s", e.message);
            }
            return null;
        }

        private string? current_executable_path() {
            return AppPaths.current_executable_path;
        }

        private void run_appimage_extract(string appimage_path, string working_dir) throws Error {
            Utils.FileUtils.ensure_executable(appimage_path);
            var cmd = new string[2];
            cmd[0] = appimage_path;
            cmd[1] = "--appimage-extract";
            string? stdout_str;
            string? stderr_str;
            int exit_status;
            Process.spawn_sync(working_dir, cmd, null, 0, null, out stdout_str, out stderr_str, out exit_status);
            if (exit_status != 0) {
                warning("AppImage extract stdout: %s", stdout_str ?? "");
                warning("AppImage extract stderr: %s", stderr_str ?? "");
                // Fallback for DwarFS-based AppImages that the runtime cannot extract
                var dwarfs_output = Path.build_filename(working_dir, SQUASHFS_ROOT_DIR);
                DirUtils.create_with_parents(dwarfs_output, 0755);
                if (DwarfsTools.extract_all(appimage_path, dwarfs_output)) {
                    return;
                }
                throw new InstallerError.EXTRACTION_FAILED("AppImage self-extract failed");
            }
        }

        /**
         * Whether <path> is a symlink AppManager created, i.e. one pointing into the applications
         * directory. A real binary, a user script or another package's symlink is not ours to
         * replace or delete (issue #175). Queried NOFOLLOW so a link left dangling by a removed
         * app still counts as ours.
         */
        private static bool bin_symlink_is_ours(string path, string? installed_path = null) {
            try {
                var info = File.new_for_path(path).query_info(
                    FileAttribute.STANDARD_IS_SYMLINK + "," + FileAttribute.STANDARD_SYMLINK_TARGET,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                if (!info.get_is_symlink()) {
                    return false;
                }
                var target = info.get_symlink_target();
                if (target == null) {
                    return false;
                }
                if (AppPaths.is_inside_applications_dir(target)) {
                    return true;
                }
                // A folder migration that partly failed still switches the configured directory, so
                // an app left behind sits outside it - its own link is ours all the same. Extracted
                // installs link to <installed_path>/AppRun, hence the prefix.
                if (installed_path == null || installed_path.strip() == "") {
                    return false;
                }
                return target == installed_path || target.has_prefix(installed_path + "/");
            } catch (Error e) {
                return false;   // absent, or unreadable: nothing we may touch
            }
        }

        /**
         * Symlink <slug> in the user bin dir to the AppImage. Links we own are replaced, so
         * upgrades keep working once a name is established; anything else is left alone and
         * `name_taken` is set (issue #175 - this used to delete whatever was there).
         */
        private string? create_bin_symlink(string exec_path, string slug, string? installed_path, out bool name_taken) {
            name_taken = false;
            var symlink_path = Path.build_filename(AppPaths.local_bin_dir, slug);
            var symlink_file = File.new_for_path(symlink_path);

            try {
                if (bin_symlink_is_ours(symlink_path, installed_path)) {
                    symlink_file.delete(null);
                }
                // Nothing was deleted for a foreign occupant, so this fails with EXISTS and is the
                // existence check too - no window between looking and linking.
                symlink_file.make_symbolic_link(exec_path, null);
            } catch (Error e) {
                if (e is IOError.EXISTS) {
                    name_taken = true;
                    warning("Not linking %s: it exists and was not created by AppManager", symlink_path);
                } else {
                    warning("Failed to create symlink for %s: %s", slug, e.message);
                }
                return null;
            }

            debug("Created symlink: %s -> %s", symlink_path, exec_path);
            return symlink_path;
        }

        private const string BIN_WRAPPER_HEADER = "#!/bin/sh\n# Generated by AppManager - launches this app inside its sandbox.\n";
        private const string ENV_WRAPPER_HEADER = "#!/bin/sh\n# Generated by AppManager - launches this app with its environment.\n";

        private static bool bin_wrapper_is_ours(string path, InstallationRecord record) {
            try {
                var info = File.new_for_path(path).query_info(
                    FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_SIZE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                if (info.get_file_type() != FileType.REGULAR || info.get_size() > 65536) {
                    return false;
                }
                string contents;
                GLib.FileUtils.get_contents(path, out contents);
                if (contents.has_prefix(ENV_WRAPPER_HEADER + "# Installation: " + record.id + "\nexec /usr/bin/env -- ")
                    && contents.has_suffix(" \"$@\"\n")) return true;
                return contents.has_prefix(BIN_WRAPPER_HEADER + "exec ")
                    && contents.contains(" %s --id=%s --target=".printf(SANDBOX_RUN_VERB, record.id))
                    && contents.has_suffix(" -- \"$@\"\n");
            } catch (Error e) {
                return false;
            }
        }

        private static bool bin_launcher_is_ours(string path, InstallationRecord record) {
            return bin_symlink_is_ours(path, record.installed_path) || bin_wrapper_is_ours(path, record);
        }

        /**
         * Applies the record's environment for terminal launches, or re-enters
         * sandbox-run where the manifest provides that environment.
         */
        private string? create_bin_wrapper(InstallationRecord record, string exec_path, string slug) {
            try {
                var script_path = Path.build_filename(AppPaths.local_bin_dir, slug);
                var script_file = File.new_for_path(script_path);
                if (bin_launcher_is_ours(script_path, record)) {
                    script_file.delete(null);
                }

                // The whole prefix, not just its first token: invoking AppManager can take
                // several words (e.g. "flatpak run <id>").
                var launcher = new StringBuilder();
                foreach (var token in uninstall_prefix) {
                    if (launcher.len > 0) {
                        launcher.append(" ");
                    }
                    launcher.append(shell_quote(token));
                }
                if (launcher.len == 0) {
                    launcher.append("app-manager");
                }

                var content = new StringBuilder();
                if (record.sandbox_enabled()) {
                    content.append(BIN_WRAPPER_HEADER);
                    content.append("exec %s %s --id=%s --target=%s -- \"$@\"\n".printf(
                        launcher.str, SANDBOX_RUN_VERB, record.id, shell_quote(exec_path)));
                } else {
                    content.append(ENV_WRAPPER_HEADER);
                    content.append("# Installation: %s\nexec /usr/bin/env -- ".printf(record.id));
                    foreach (var variable in record.get_effective_env_vars()) {
                        content.append(shell_quote(variable) + " ");
                    }
                    content.append("%s \"$@\"\n".printf(shell_quote(exec_path)));
                }

                // Exclusive creation also protects a foreign file appearing after deletion.
                var stream = script_file.create(FileCreateFlags.PRIVATE);
                size_t written;
                stream.write_all(content.str.data, out written);
                stream.close();
                Utils.FileUtils.ensure_executable(script_path);
                debug("Created application wrapper: %s", script_path);
                return script_path;
            } catch (Error e) {
                if (e is IOError.EXISTS) {
                    record.bin_conflict_slug = slug;
                }
                warning("Failed to create application wrapper for %s: %s", slug, e.message);
                return null;
            }
        }

        private static string shell_quote(string token) {
            return "'%s'".printf(token.replace("'", "'\\''"));
        }

        /**
         * Uses a wrapper when sandboxing or environment variables need applying;
         * otherwise the app's ~/.local/bin entry is a plain symlink.
         *
         * record.bin_symlink can therefore be a regular file. PathMigrationService
         * updates the paths inside these scripts as well as symlink targets.
         */
        private string? create_bin_launcher(InstallationRecord record, string exec_path, string slug) {
            record.bin_conflict_slug = null;
            if (record.sandbox_enabled() || record.get_effective_env_vars().length > 0) {
                return create_bin_wrapper(record, exec_path, slug);
            }
            var path = Path.build_filename(AppPaths.local_bin_dir, slug);
            // Clearing the environment or turning sandboxing off can restore a symlink.
            if (bin_wrapper_is_ours(path, record)) {
                try {
                    File.new_for_path(path).delete(null);
                } catch (Error e) {
                    warning("Failed to remove application wrapper for %s: %s", slug, e.message);
                    return null;
                }
            }
            bool name_taken;
            var link = create_bin_symlink(exec_path, slug, record.installed_path, out name_taken);
            if (name_taken) record.bin_conflict_slug = slug;
            return link;
        }

        public bool ensure_bin_symlink_for_record(InstallationRecord record, string exec_path, string slug) {
            if (exec_path.strip() == "") {
                return false;
            }

            var link = create_bin_launcher(record, exec_path, slug);
            if (link == null) {
                return false;
            }

            record.bin_symlink = link;
            registry.persist(false);
            return true;
        }

        /**
         * Resolve the effective executable path for an installed record based on its desktop file.
         * This mirrors the runtime resolution used when creating the desktop entry, but can be
         * called later (e.g., from the Details window) without reimplementing parsing logic.
         */
        public string resolve_exec_path_for_record(InstallationRecord record) {
            var installed_path = record.installed_path ?? "";
            var stored_exec = record.entry_exec;

            // For extracted AppImages (directory), always use AppRun
            if (installed_path != "" && File.new_for_path(installed_path).query_file_type(FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                return Path.build_filename(installed_path, "AppRun");
            }

            if (stored_exec != null && stored_exec.strip() != "") {
                var token = stored_exec.strip();
                if (Path.is_absolute(token)) {
                    return token;
                }
            }

            if (installed_path != "" && File.new_for_path(installed_path).query_file_type(FileQueryInfoFlags.NONE) != FileType.DIRECTORY) {
                return installed_path;
            }

            string exec_value = "";

            if (record.desktop_file != null && record.desktop_file.strip() != "") {
                var entry = new DesktopEntry(record.desktop_file);
                exec_value = entry.exec ?? "";
            }

            return DesktopEntry.resolve_exec_path(exec_value, record.installed_path);
        }

        public bool remove_bin_symlink_for_record(InstallationRecord record) {
            if (record.bin_symlink == null || record.bin_symlink.strip() == "") {
                return true;
            }
            try {
                if (bin_launcher_is_ours(record.bin_symlink, record)) {
                    File.new_for_path(record.bin_symlink).delete(null);
                    debug("Removed symlink: %s", record.bin_symlink);
                }
                record.bin_symlink = null;
                registry.persist(false);
                return true;
            } catch (Error e) {
                warning("Failed to remove symlink for %s: %s", record.name, e.message);
                return false;
            }
        }

        /**
         * Rewrites an installed record's desktop file to reflect the record's effective values
         * (custom values and cleared values). This centralizes desktop entry edits that used to
         * be scattered across the UI.
         */
        public void apply_record_customizations_to_desktop(InstallationRecord record) {
            if (record.desktop_file == null || record.desktop_file.strip() == "") {
                return;
            }

            var desktop_path = record.desktop_file;
            if (!File.new_for_path(desktop_path).query_exists()) {
                return;
            }

            bool is_terminal = false;
            var entry = new DesktopEntry(desktop_path);
            is_terminal = entry.terminal;

            var exec_target = resolve_exec_path_for_record(record);

            // Refresh the manifest before the Exec lines are written, so a launch racing
            // this rewrite never finds a sandbox-run line with no manifest behind it.
            SandboxConfig.sync_manifest(record, registry.list());

            var effective_icon = record.get_effective_icon_name();
            var effective_keywords = record.get_effective_keywords();
            var effective_wmclass = record.get_effective_startup_wm_class();
            var effective_args = record.get_effective_commandline_args();
            var effective_update_link = record.get_effective_update_link();
            var effective_web_page = record.get_effective_web_page();
            var effective_name = record.get_effective_name();

            try {
                var new_contents = rewrite_desktop(
                    desktop_path,
                    exec_target,
                    record,
                    is_terminal,
                    "",
                    false,
                    effective_icon,
                    effective_keywords,
                    effective_wmclass,
                    effective_args,
                    effective_update_link,
                    effective_web_page,
                    effective_name
                );

                if (!GLib.FileUtils.set_contents(desktop_path, new_contents)) {
                    warning("Failed to write updated desktop file: %s", desktop_path);
                }
            } catch (Error e) {
                warning("Failed to rewrite desktop file %s: %s", desktop_path, e.message);
            }

            write_autostart_entry(record, exec_target);
            apply_record_customizations_to_sub_desktops(record);
            refresh_bin_launcher_for_record(record, exec_target);
        }

        private const string AUTOSTART_MARKER = "X-AppManager-Autostart";
        // Meaningless at login; systemd's autostart generator drops them too.
        private const string[] EXEC_FIELD_CODES = { "%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k", "%v", "%m" };

        /**
         * Own prefix instead of the app's desktop file name: apps like Bitwarden write
         * ~/.config/autostart/<name>.desktop pointing at their temporary mount, and
         * rewrite or delete it at runtime.
         */
        public static string? autostart_path(InstallationRecord record) {
            if (record.desktop_file == null || record.desktop_file.strip() == "") {
                return null;
            }
            return Path.build_filename(Environment.get_user_config_dir(), "autostart",
                "appmanager-" + Path.get_basename(record.desktop_file));
        }

        public void sync_autostart_entry(InstallationRecord record) {
            write_autostart_entry(record, resolve_exec_path_for_record(record));
        }

        // Writes or removes the entry to match record.autostart_enabled.
        private void write_autostart_entry(InstallationRecord record, string exec_target) {
            var path = autostart_path(record);
            if (path == null) {
                return;
            }
            // AppManager's own daemon has a separate autostart entry.
            if (!record.autostart_enabled || record.is_self_app()) {
                remove_autostart_entry(record);
                return;
            }

            var args = new StringBuilder();
            var extra = (record.custom_autostart_args ?? "").strip();
            foreach (var tok in ((record.get_effective_commandline_args() ?? "") + " " + extra).split(" ")) {
                var t = tok.strip();
                if (t == "" || t in EXEC_FIELD_CODES) continue;
                if (args.len > 0) args.append(" ");
                args.append(t);
            }
            var exec = build_exec_line(record, exec_target, args.str);
            if (record.custom_autostart_delay > 0) {
                // X-GNOME-Autostart-Delay is an Ubuntu patch that systemd's generator ignores.
                var script = "sleep %d; exec \"$@\"".printf(record.custom_autostart_delay);
                exec = "/bin/sh -c \"%s\" sh %s".printf(escape_env_exec_token(script), exec);
            }

            var keyfile = new KeyFile();
            var group = KeyFileDesktop.GROUP;
            keyfile.set_string(group, "Type", "Application");
            keyfile.set_string(group, "Name", record.get_effective_name());
            var icon = record.get_effective_icon_name();
            if (icon != null && icon.strip() != "") {
                keyfile.set_string(group, "Icon", icon);
            }
            keyfile.set_string(group, "Exec", exec);
            keyfile.set_boolean(group, AUTOSTART_MARKER, true);
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0755);
                GLib.FileUtils.set_contents(path, keyfile.to_data());
            } catch (Error e) {
                warning("Failed to write autostart entry %s: %s", path, e.message);
            }
        }

        public static void remove_autostart_entry(InstallationRecord record) {
            var path = autostart_path(record);
            if (path == null || !GLib.FileUtils.test(path, FileTest.EXISTS)) {
                return;
            }
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(path, KeyFileFlags.NONE);
                if (keyfile.has_key(KeyFileDesktop.GROUP, AUTOSTART_MARKER)) {
                    File.new_for_path(path).delete();
                }
            } catch (Error e) {
                warning("Failed to remove autostart entry %s: %s", path, e.message);
            }
        }

        /**
         * Swaps the ~/.local/bin entry between a plain symlink and a sandbox wrapper so a
         * terminal launch matches what the desktop entry now does. No-op for an app that
         * opted out of $PATH, whose bin entry is absent by design.
         */
        private void refresh_bin_launcher_for_record(InstallationRecord record, string exec_target) {
            if (record.bin_symlink == null || record.bin_symlink.strip() == "") {
                return;
            }
            if (exec_target.strip() == "") {
                return;
            }
            var slug = Path.get_basename(record.bin_symlink);
            var link = create_bin_launcher(record, exec_target, slug);
            if (link != null) {
                record.bin_symlink = link;
                registry.persist(false);
            }
        }

        /**
         * Re-applies custom env vars and command-line args to all installed sub-entries
         * (multi-component AppImages). Mirrors the primary entry: each sub-entry keeps its
         * pristine args (from original_sub_args, captured at install) with the user's custom
         * args appended and env prefix prepended. Other fields are left untouched.
         */
        private void apply_record_customizations_to_sub_desktops(InstallationRecord record) {
            var desktops = record.extra_desktop_files;
            var symlinks = record.extra_bin_symlinks;
            if (desktops == null || symlinks == null || desktops.length != symlinks.length) {
                return;
            }

            // Map installed desktop basename -> pristine args captured at install.
            var pristine = new Gee.HashMap<string, string>();
            foreach (var pair in record.original_sub_args ?? new string[0]) {
                var eq = pair.index_of_char('=');
                if (eq < 0) continue;
                pristine.set(pair.substring(0, eq), pair.substring(eq + 1));
            }

            bool backfilled = false;
            for (int i = 0; i < desktops.length; i++) {
                var sub_desktop = desktops[i];
                // Records written by older versions can list the primary desktop file among
                // the extras; rewriting it here would clobber the primary Exec just written.
                if (sub_desktop == record.desktop_file) continue;
                if (!File.new_for_path(sub_desktop).query_exists()) continue;
                var basename = Path.get_basename(sub_desktop);
                string args;
                if (pristine.has_key(basename)) {
                    args = pristine.get(basename);
                } else {
                    // Records from versions that didn't capture original_sub_args: derive the
                    // pristine args from the on-disk Exec (minus any user-added args) and
                    // backfill the record so later rewrites don't compound.
                    args = derive_pristine_sub_args(sub_desktop, record);
                    pristine.set(basename, args);
                    backfilled = true;
                }
                try {
                    // sub_icon_name = null preserves the icon already written at install.
                    var contents = rewrite_sub_desktop(sub_desktop, symlinks[i], null, args, record,
                        entry_env_vars(record.original_sub_env_vars, basename));
                    if (!GLib.FileUtils.set_contents(sub_desktop, contents)) {
                        warning("Failed to write updated sub-desktop: %s", sub_desktop);
                    }
                } catch (Error e) {
                    warning("Failed to rewrite sub-desktop %s: %s", sub_desktop, e.message);
                }
            }

            if (backfilled) {
                var entries = new Gee.ArrayList<string>();
                foreach (var e in pristine.entries) {
                    entries.add("%s=%s".printf(e.key, e.value));
                }
                record.original_sub_args = entries.to_array();
                registry.persist(false);
            }
        }

        // Pristine args for a sub-desktop whose record predates original_sub_args capture:
        // the current on-disk Exec args minus tokens the user added via custom args.
        private string derive_pristine_sub_args(string sub_desktop_path, InstallationRecord record) {
            var entry = new DesktopEntry(sub_desktop_path);
            var current = DesktopEntry.extract_exec_arguments(entry.exec ?? "") ?? "";
            if (current.strip() == "") return "";
            var user_tokens = new Gee.HashSet<string>();
            foreach (var tok in user_added_commandline_args(record).split(" ")) {
                var t = tok.strip();
                if (t != "") user_tokens.add(t);
            }
            var kept = new StringBuilder();
            foreach (var tok in current.split(" ")) {
                var t = tok.strip();
                if (t == "" || user_tokens.contains(t)) continue;
                if (kept.len > 0) kept.append(" ");
                kept.append(t);
            }
            return kept.str;
        }

        /**
         * Updates a single key inside the [Desktop Entry] group.
         * If value is empty, the key is removed (except Exec, which is preserved).
         */
        public void set_desktop_entry_property(string desktop_file_path, string key, string value) {
            if (desktop_file_path == null || desktop_file_path.strip() == "") {
                return;
            }

            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(desktop_file_path, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);

                if (value.strip() == "") {
                    if (key != "Exec") {
                        try {
                            if (keyfile.has_key("Desktop Entry", key)) {
                                keyfile.remove_key("Desktop Entry", key);
                            }
                        } catch (Error e) {
                            debug("Failed to remove key %s from desktop entry: %s", key, e.message);
                        }
                    } else {
                        keyfile.set_string("Desktop Entry", key, value);
                    }
                } else {
                    keyfile.set_string("Desktop Entry", key, value);
                }

                var data = keyfile.to_data();
                GLib.FileUtils.set_contents(desktop_file_path, data);
            } catch (Error e) {
                warning("Failed to update desktop file %s: %s", desktop_file_path, e.message);
            }
        }

        /**
         * Updates the MIME database and desktop file cache so that file associations work.
         * Runs update-desktop-database on ~/.local/share/applications.
         */
        private void update_desktop_database() {
            try {
                string[] argv = { "update-desktop-database", AppPaths.desktop_dir };
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);
                if (exit_status != 0) {
                    debug("update-desktop-database returned non-zero exit status: %d", exit_status);
                }
            } catch (Error e) {
                // update-desktop-database may not be available on all systems
                debug("Failed to run update-desktop-database: %s", e.message);
            }
        }

        /**
         * Installs AppManager's icons (main and symbolic) from GResource to the hicolor theme.
         * Called on startup and when installing AppManager itself.
         */
        public static void install_symbolic_icon() {
            bool needs_cache_update = false;

            // Install main icon
            var main_dest = AppPaths.main_icon_path;
            if (!GLib.FileUtils.test(main_dest, FileTest.EXISTS)) {
                try {
                    var bytes = resources_lookup_data(
                        "/com/github/AppManager/icons/hicolor/scalable/apps/com.github.AppManager.svg",
                        ResourceLookupFlags.NONE);
                    DirUtils.create_with_parents(Path.get_dirname(main_dest), 0755);
                    GLib.FileUtils.set_data(main_dest, bytes.get_data());
                    needs_cache_update = true;
                } catch (Error e) {
                    debug("Main icon install: %s", e.message);
                }
            }

            // Install symbolic icon
            var symbolic_dest = AppPaths.symbolic_icon_path;
            if (!GLib.FileUtils.test(symbolic_dest, FileTest.EXISTS)) {
                try {
                    var bytes = resources_lookup_data(
                        "/com/github/AppManager/icons/hicolor/symbolic/apps/com.github.AppManager-symbolic.svg",
                        ResourceLookupFlags.NONE);
                    DirUtils.create_with_parents(Path.get_dirname(symbolic_dest), 0755);
                    GLib.FileUtils.set_data(symbolic_dest, bytes.get_data());
                    needs_cache_update = true;
                } catch (Error e) {
                    debug("Symbolic icon install: %s", e.message);
                }
            }

            if (needs_cache_update) {
                try {
                    Process.spawn_command_line_async("gtk4-update-icon-cache -f -t " +
                        Path.build_filename(Environment.get_user_data_dir(), "icons", "hicolor"));
                } catch (Error e) {
                    debug("Icon cache update: %s", e.message);
                }
            }
        }

        /**
         * Removes AppManager's icons (main and symbolic) from the hicolor theme.
         * Called when uninstalling AppManager itself.
         */
        public static void uninstall_symbolic_icon() {
            bool needs_cache_update = false;

            // Remove main icon
            var main_path = AppPaths.main_icon_path;
            if (GLib.FileUtils.test(main_path, FileTest.EXISTS)) {
                try {
                    File.new_for_path(main_path).delete(null);
                    needs_cache_update = true;
                } catch (Error e) {
                    debug("Main icon uninstall: %s", e.message);
                }
            }

            // Remove symbolic icon
            var symbolic_path = AppPaths.symbolic_icon_path;
            if (GLib.FileUtils.test(symbolic_path, FileTest.EXISTS)) {
                try {
                    File.new_for_path(symbolic_path).delete(null);
                    needs_cache_update = true;
                } catch (Error e) {
                    debug("Symbolic icon uninstall: %s", e.message);
                }
            }

            if (needs_cache_update) {
                try {
                    Process.spawn_command_line_async("gtk4-update-icon-cache -f -t " +
                        Path.build_filename(Environment.get_user_data_dir(), "icons", "hicolor"));
                } catch (Error e) {
                    debug("Icon cache update: %s", e.message);
                }
            }
        }
    }
}
