namespace AppManager.Core {
    /**
     * The permission model behind the "Privacy & Security" page: presets, the rules
     * for deciding which preset a set of toggles corresponds to, and the paths the
     * sandbox occupies. Persisting the permissions is SandboxManifest's job; turning
     * them into a command line is SandboxBwrap's.
     *
     * Every toggle reads as a permission, so true always means "the app is allowed
     * this", matching the UI switches one-for-one.
     */
    public class SandboxConfig {
        /**
         * Applies a named preset's permissions to the record and stamps the profile.
         * "custom" and "off" carry no permissions of their own, so they only set the label.
         *
         * Both real presets keep hardware acceleration on: software rendering makes
         * apps unusably slow without materially improving isolation.
         */
        public static void apply_preset(InstallationRecord record, string profile) {
            switch (profile) {
                case SANDBOX_PROFILE_STANDARD:
                    apply_toggles(record, true);
                    break;
                case SANDBOX_PROFILE_STRICT:
                    apply_toggles(record, false);
                    break;
                default:
                    break;
            }
            record.sandbox_profile = profile;
        }

        /**
         * The two presets differ only in whether the "convenience" permissions are
         * granted; everything else is fixed. `open` selects Standard over Strict.
         */
        private static void apply_toggles(InstallationRecord record, bool open) {
            record.sandbox_allow_network = open;
            record.sandbox_allow_audio = open;
            record.sandbox_allow_x11 = open;
            record.sandbox_allow_notifications = open;
            record.sandbox_allow_tray = open;
            record.sandbox_allow_downloads = open;

            record.sandbox_allow_gpu = true;

            record.sandbox_allow_dbus = false;
            record.sandbox_allow_camera = false;
            record.sandbox_allow_input = false;
            record.sandbox_allow_bluetooth = false;
            record.sandbox_allow_location = false;

            record.sandbox_allow_documents = false;
            record.sandbox_allow_desktop = false;
            record.sandbox_allow_pictures = false;
            record.sandbox_allow_videos = false;
            record.sandbox_allow_music = false;
            record.sandbox_extra_dirs = null;
        }

        /**
         * Returns the preset whose permissions match the record's current state,
         * or "custom" when none does. Never returns "off" - callers decide that
         * from sandbox_enabled().
         */
        public static string detect_profile(InstallationRecord record) {
            if (matches(record, true)) {
                return SANDBOX_PROFILE_STANDARD;
            }
            if (matches(record, false)) {
                return SANDBOX_PROFILE_STRICT;
            }
            return SANDBOX_PROFILE_CUSTOM;
        }

        private static bool matches(InstallationRecord r, bool open) {
            return r.sandbox_allow_network == open
                && r.sandbox_allow_audio == open
                && r.sandbox_allow_x11 == open
                && r.sandbox_allow_notifications == open
                && r.sandbox_allow_tray == open
                && r.sandbox_allow_downloads == open
                && r.sandbox_allow_gpu
                && !r.sandbox_allow_dbus
                && !r.sandbox_allow_camera
                && !r.sandbox_allow_input
                && !r.sandbox_allow_bluetooth
                && !r.sandbox_allow_location
                && !r.sandbox_allow_documents
                && !r.sandbox_allow_desktop
                && !r.sandbox_allow_pictures
                && !r.sandbox_allow_videos
                && !r.sandbox_allow_music
                && (r.sandbox_extra_dirs == null || r.sandbox_extra_dirs.length == 0);
        }

        /**
         * Path of the app's persistent sandboxed home. Mirrors the existing
         * <installed_path>.home / .config convention.
         *
         * An explicit path outside the AppImage's own portable-home names is required:
         * <installed_path>.home would be adopted by the AppImage runtime as a portable
         * home, silently flipping AppManager's own portable .home toggle.
         */
        public static string sandbox_home_path(InstallationRecord record) {
            return "%s.sandbox".printf(record.installed_path ?? "");
        }

        /**
         * Whether this record can actually be sandboxed. EXTRACTED installs are
         * excluded for now: the engine mounts a single AppImage file, and an extracted
         * AppDir would need a different (read-only bind) path that is not implemented.
         */
        public static bool supports_record(InstallationRecord record) {
            return record.mode == InstallMode.PORTABLE
                && record.installed_path != null
                && record.installed_path.strip() != ""
                && record.original_startup_wm_class != APPLICATION_ID;
        }

        /**
         * Resolves a path to its real location, following symlinks.
         *
         * Granting a symlink itself is useless and actively harmful: bwrap resolves the
         * bind source to its target but creates the destination at the literal path, so
         * mounting onto a symlink that sits inside an already-bound read-only parent
         * fails outright and the app never starts. Binding the target directly both
         * works and makes the symlink inside that parent resolve.
         *
         * Returns the input unchanged when it cannot be resolved (e.g. it does not
         * exist yet), since the "-try" bind will simply skip it.
         */
        public static string canonicalize(string path) {
            var resolved = Posix.realpath(path);
            return (resolved != null && resolved != "") ? resolved : path;
        }

        /**
         * Writes a record's manifest, or removes it when the record is not sandboxed.
         * Single entry point so callers never have to think about which of the two
         * they want.
         *
         * `existing` is only needed to keep two records from being handed the same
         * sandbox app id; pass the registry contents where they are at hand.
         */
        public static void sync_manifest(InstallationRecord record, InstallationRecord[]? existing = null) {
            if (record.sandbox_enabled()) {
                SandboxIdentity.ensure_app_id(record, existing);
                SandboxManifest.write_for_record(record);
            } else {
                SandboxManifest.remove(record.id);
            }
        }

        /**
         * Rewrites the manifest of every sandboxed record and drops the file of any
         * record that is no longer sandboxed.
         *
         * Called at startup so a change to the manifest format or to what a permission
         * implies reaches apps that were sandboxed by an older build. Writing them is
         * cheap - a few hundred bytes each - and the launcher reads the file fresh on
         * every launch, so the next start picks it up.
         *
         * Returns true when a record was modified - an app id was assigned to one that
         * had none - and the registry therefore needs persisting. Without that the id
         * would be generated afresh on every start, and the Wayland security context
         * keyed by it would stop identifying the app.
         */
        public static bool refresh_all(InstallationRecord[] records) {
            // Sorted so that, if two apps of the same name both need an id, which one
            // gets the "_2" suffix does not depend on hash-table order.
            var ordered = new Gee.ArrayList<InstallationRecord>();
            foreach (var record in records) {
                ordered.add(record);
            }
            ordered.sort((a, b) => strcmp(a.id, b.id));

            bool changed = false;
            var live = new Gee.HashSet<string>();
            foreach (var record in ordered) {
                if (record.sandbox_enabled()) {
                    if (record.sandbox_app_id == null || record.sandbox_app_id.strip() == "") {
                        SandboxIdentity.ensure_app_id(record, records);
                        changed = true;
                    }
                    SandboxManifest.write_for_record(record);
                    live.add("%s%s".printf(record.id, SANDBOX_MANIFEST_SUFFIX));
                } else {
                    SandboxManifest.remove(record.id);
                }
            }

            // Drop files left behind by records that vanished without an uninstall
            // (a hand-edited registry, a restored backup), so the directory cannot
            // grow without bound. ".args" files come from unreleased test builds of
            // the first sandbox implementation and are never read again.
            try {
                var dir = Dir.open(AppPaths.sandbox_dir);
                var orphans = new Gee.ArrayList<string>();
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (name.has_suffix(".args")
                        || (name.has_suffix(SANDBOX_MANIFEST_SUFFIX) && !live.contains(name))) {
                        orphans.add(name);
                    }
                }
                foreach (var orphan in orphans) {
                    var file = File.new_for_path(Path.build_filename(AppPaths.sandbox_dir, orphan));
                    file.delete(null);
                    debug("Removed orphaned sandbox file %s", orphan);
                }
            } catch (Error e) {
                debug("Could not scan sandbox dir for orphans: %s", e.message);
            }
            return changed;
        }
    }
}
