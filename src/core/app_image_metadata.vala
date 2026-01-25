namespace AppManager.Core {
    public class AppImageMetadata : Object {
    public File file { get; private set; }
    public string path { owned get { return file.get_path(); } }
    public string basename { owned get { return file.get_basename(); } }
        public string display_name { get; private set; }
        public bool is_executable { get; private set; }
        public string checksum { get; private set; }
        public string? update_info { get; private set; }

        public AppImageMetadata(File file) throws Error {
            this.file = file;
            if (!file.query_exists()) {
                throw new FileError.NOENT("AppImage not found: %s", file.get_path());
            }
            display_name = derive_name(file.get_basename());
            checksum = Utils.FileUtils.compute_checksum(file.get_path());
            is_executable = detect_executable();
            update_info = extract_update_info(file.get_path());
        }

        /**
         * Extract update information from AppImage's .upd_info ELF section.
         * This section contains update URLs in formats like:
         *   - zsync|https://example.com/App.AppImage.zsync
         *   - gh-releases-zsync|owner|repo|latest|App-*x86_64.AppImage.zsync
         * Returns null if no update info is found.
         * 
         * This method parses the ELF binary directly without external tools.
         */
        private static string? extract_update_info(string appimage_path) {
            try {
                var file = File.new_for_path(appimage_path);
                var stream = file.read();
                var data = new DataInputStream(stream);
                data.byte_order = DataStreamByteOrder.LITTLE_ENDIAN;

                // Read ELF magic and verify
                uint8[] elf_magic = new uint8[4];
                stream.read(elf_magic);
                if (elf_magic[0] != 0x7F || elf_magic[1] != 'E' || elf_magic[2] != 'L' || elf_magic[3] != 'F') {
                    return null;
                }

                // Read ELF class (32 or 64 bit)
                uint8 elf_class = data.read_byte();
                if (elf_class != 2) {
                    // Only support 64-bit ELF (class 2)
                    return null;
                }

                // Skip to section header offset (e_shoff at offset 40 for ELF64)
                stream.seek(40, SeekType.SET);
                int64 e_shoff = (int64) data.read_uint64();

                // Skip to e_shentsize (offset 58), e_shnum (offset 60), e_shstrndx (offset 62)
                stream.seek(58, SeekType.SET);
                uint16 e_shentsize = data.read_uint16();
                uint16 e_shnum = data.read_uint16();
                uint16 e_shstrndx = data.read_uint16();

                if (e_shoff == 0 || e_shnum == 0 || e_shstrndx >= e_shnum) {
                    return null;
                }

                // Read section header string table section header
                stream.seek(e_shoff + e_shstrndx * e_shentsize, SeekType.SET);
                data.read_uint32(); // sh_name
                data.read_uint32(); // sh_type
                data.read_uint64(); // sh_flags
                data.read_uint64(); // sh_addr
                int64 shstrtab_offset = (int64) data.read_uint64();
                int64 shstrtab_size = (int64) data.read_uint64();

                // Read the section header string table
                uint8[] shstrtab = new uint8[shstrtab_size];
                stream.seek(shstrtab_offset, SeekType.SET);
                stream.read(shstrtab);

                // Search through section headers for .upd_info
                for (int i = 0; i < e_shnum; i++) {
                    stream.seek(e_shoff + i * e_shentsize, SeekType.SET);
                    uint32 sh_name = data.read_uint32();
                    data.read_uint32(); // sh_type
                    data.read_uint64(); // sh_flags
                    data.read_uint64(); // sh_addr
                    int64 sh_offset = (int64) data.read_uint64();
                    int64 sh_size = (int64) data.read_uint64();

                    // Get section name from string table
                    if (sh_name >= shstrtab_size) {
                        continue;
                    }

                    var name_builder = new StringBuilder();
                    for (int64 j = sh_name; j < shstrtab_size && shstrtab[j] != 0; j++) {
                        name_builder.append_c((char) shstrtab[j]);
                    }
                    string section_name = name_builder.str;

                    if (section_name == ".upd_info") {
                        // Found the section, read its content
                        if (sh_size == 0 || sh_size > 4096) {
                            return null;
                        }

                        uint8[] content = new uint8[sh_size];
                        stream.seek(sh_offset, SeekType.SET);
                        stream.read(content);

                        // Find the null terminator or end
                        int64 len = 0;
                        for (int64 j = 0; j < sh_size && content[j] != 0; j++) {
                            len++;
                        }

                        if (len == 0) {
                            return null;
                        }

                        string result = (string) content;
                        result = result.strip();
                        return result.length > 0 ? result : null;
                    }
                }

                return null;
            } catch (Error e) {
                debug("Failed to extract .upd_info: %s", e.message);
                return null;
            }
        }

        private bool detect_executable() {
            try {
                var info = file.query_info("unix::mode", FileQueryInfoFlags.NONE);
                uint32 mode = info.get_attribute_uint32("unix::mode");
                return (mode & 0100) != 0;
            } catch (Error e) {
                warning("Failed to query file mode: %s", e.message);
                return false;
            }
        }

        public string sanitized_basename() {
            var stem = Path.get_basename(file.get_path());
            if (stem.has_suffix(".AppImage")) {
                stem = stem.substring(0, (int)stem.length - ".AppImage".length);
            }
            var builder = new StringBuilder();
            for (int i = 0; i < stem.length; i++) {
                char c = stem[i];
                if (c.isalnum() || c == '-' || c == '_') {
                    builder.append_c(c);
                } else {
                    builder.append_c('-');
                }
            }
            return builder.str.strip();
        }

        private string derive_name(string filename) {
            var name = filename;
            if (name.has_suffix(".AppImage")) {
                name = name.substring(0, (int)name.length - 9);
            }
            name = name.replace("-", " ");
            name = name.replace("_", " ");
            if (name.length == 0) {
                return "AppImage";
            }
            var first = name.substring(0, 1).up();
            var rest = name.substring(1);
            return first + rest;
        }
    }
}
