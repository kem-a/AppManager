namespace AppManager.Core {
    /**
     * What an AppImage's embedded runtime needs in order to mount itself.
     * uruntime mounts through a user namespace when the setuid helper is
     * missing, so it never counts as depending on FUSE.
     */
    public enum FuseRequirement {
        NONE,
        FUSE2,       // classic AppImageKit runtime: dlopens libfuse.so.2
        FUSERMOUNT   // static type2-runtime: needs a fusermount helper on $PATH
    }

    public class FuseSupport : Object {
        // Markers found in the uncompressed runtime that precedes the payload.
        private const string URUNTIME_MARKER = "uruntime";
        private const string FUSE2_MARKER = "libfuse.so.2";
        private const string FUSERMOUNT_MARKER = "fusermount";

        // Largest runtime seen in the wild is ~4 MB (uruntime with dwarfs).
        private const int64 MAX_RUNTIME_BYTES = 8 * 1024 * 1024;

        private static Gee.HashMap<string, FuseRequirement>? cache = null;

        private static bool system_checked = false;
        private static bool has_fusermount2 = false;
        private static bool has_fusermount3 = false;
        private static bool has_libfuse2 = false;

        /**
         * Classifies the runtime of an AppImage by scanning its ELF prefix.
         * Results are cached per path and modification time.
         */
        public static FuseRequirement detect(string appimage_path) {
            if (cache == null) {
                cache = new Gee.HashMap<string, FuseRequirement>();
            }

            var key = cache_key(appimage_path);
            if (cache.has_key(key)) {
                return cache.get(key);
            }

            var requirement = probe_runtime(appimage_path);
            cache.set(key, requirement);
            return requirement;
        }

        /** True when this system cannot satisfy the given requirement. */
        public static bool is_unmet(FuseRequirement requirement) {
            check_system();

            switch (requirement) {
                case FuseRequirement.FUSE2:
                    return !has_libfuse2 || !has_fusermount2;
                case FuseRequirement.FUSERMOUNT:
                    return !has_fusermount2 && !has_fusermount3;
                default:
                    return false;
            }
        }

        /** True when the installed app depends on FUSE bits this system lacks. */
        public static bool record_cannot_mount(InstallationRecord record) {
            if (record.mode == InstallMode.EXTRACTED) {
                return false;
            }
            if (record.installed_path == null || record.installed_path.strip() == "") {
                return false;
            }
            return is_unmet(detect(record.installed_path));
        }

        private static void check_system() {
            if (system_checked) {
                return;
            }
            system_checked = true;

            has_fusermount2 = GLib.Environment.find_program_in_path("fusermount") != null;
            has_fusermount3 = GLib.Environment.find_program_in_path("fusermount3") != null;

            var module = GLib.Module.open(FUSE2_MARKER, GLib.ModuleFlags.LAZY);
            has_libfuse2 = module != null;
            if (module != null) {
                module.close();
            }
        }

        private static string cache_key(string appimage_path) {
            int64 mtime = 0;
            try {
                var info = File.new_for_path(appimage_path)
                    .query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                mtime = (int64)info.get_attribute_uint64(FileAttribute.TIME_MODIFIED);
            } catch (Error e) {
                debug("Failed to stat %s: %s", appimage_path, e.message);
            }
            return "%s:%lld".printf(appimage_path, mtime);
        }

        private static FuseRequirement probe_runtime(string appimage_path) {
            int64 offset = AppImageAssets.get_payload_offset(appimage_path);
            if (offset <= 0 || offset > MAX_RUNTIME_BYTES) {
                return FuseRequirement.NONE;
            }

            uint8[] runtime = new uint8[offset];
            try {
                var stream = File.new_for_path(appimage_path).read();
                size_t bytes_read;
                stream.read_all(runtime, out bytes_read);
                stream.close();
                if (bytes_read < offset) {
                    return FuseRequirement.NONE;
                }
            } catch (Error e) {
                debug("Failed to read runtime of %s: %s", appimage_path, e.message);
                return FuseRequirement.NONE;
            }

            if (contains(runtime, URUNTIME_MARKER)) {
                return FuseRequirement.NONE;
            }
            if (contains(runtime, FUSE2_MARKER)) {
                return FuseRequirement.FUSE2;
            }
            if (contains(runtime, FUSERMOUNT_MARKER)) {
                return FuseRequirement.FUSERMOUNT;
            }
            return FuseRequirement.NONE;
        }

        private static bool contains(uint8[] haystack, string needle) {
            int needle_length = needle.length;
            if (needle_length == 0 || haystack.length < needle_length) {
                return false;
            }

            for (int i = 0; i <= haystack.length - needle_length; i++) {
                int j = 0;
                while (j < needle_length && haystack[i + j] == (uint8)needle[j]) {
                    j++;
                }
                if (j == needle_length) {
                    return true;
                }
            }
            return false;
        }
    }
}
