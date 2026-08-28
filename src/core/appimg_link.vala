using GLib;

namespace AppManager.Core {
    public const string APPIMG_URI_SCHEME = "appimg";

    public errordomain AppimgLinkError {
        INVALID_LINK,
        UNSUPPORTED_ACTION,
        INSECURE_URL,
        SIZE_MISMATCH,
        CHECKSUM_MISMATCH
    }

    /**
     * A parsed `appimg://install?url=…&sha256=…` deep link from a web store.
     * Nothing in it is trusted: https only, the file name is rebuilt, and the
     * declared size/checksum are enforced against the bytes received.
     */
    public class AppimgLink : Object {
        public string url { get; private set; }
        public string host { get; private set; }
        public string filename { get; private set; }
        public string? sha256 { get; private set; }
        public string? name { get; private set; }
        public string? version { get; private set; }
        // Name for the UI: the one from the link, else the bare file name.
        public string display_name {
            owned get {
                if (name != null) {
                    return name;
                }
                return filename.down().has_suffix(".appimage")
                    ? filename.substring(0, filename.length - ".AppImage".length)
                    : filename;
            }
        }
        // Size declared by the link, or -1 when it carries none.
        public int64 size { get; private set; }

        // Download progress, polled by the UI while the transfer runs.
        public int64 received_bytes = 0;
        public int64 total_bytes = -1;

        private AppimgLink() {
            size = -1;
        }

        public static AppimgLink parse(string link) throws AppimgLinkError {
            Uri uri;
            try {
                uri = Uri.parse(link, UriFlags.NONE);
            } catch (Error e) {
                throw new AppimgLinkError.INVALID_LINK(_("This is not a valid install link."));
            }

            if (uri.get_scheme() != APPIMG_URI_SCHEME) {
                throw new AppimgLinkError.INVALID_LINK(_("This is not a valid install link."));
            }

            // appimg://install?… carries the action in the host, appimg:install?…
            // in the path.
            var action = uri.get_host();
            if (action == null || action.strip() == "") {
                action = (uri.get_path() ?? "").replace("/", "").strip();
            }
            if (action != "install") {
                throw new AppimgLinkError.UNSUPPORTED_ACTION(
                    _("Unsupported install link action “%s”.").printf(action));
            }

            HashTable<string, string> params;
            try {
                params = Uri.parse_params(uri.get_query() ?? "", -1, "&", UriParamsFlags.NONE);
            } catch (Error e) {
                throw new AppimgLinkError.INVALID_LINK(_("The install link is malformed."));
            }

            var raw_url = params.lookup("url");
            if (raw_url == null || raw_url.strip() == "") {
                throw new AppimgLinkError.INVALID_LINK(_("The install link carries no download URL."));
            }
            var download_url = raw_url.strip();

            Uri target;
            try {
                target = Uri.parse(download_url, UriFlags.NONE);
            } catch (Error e) {
                throw new AppimgLinkError.INVALID_LINK(_("The download URL in the install link is malformed."));
            }
            if (target.get_scheme() != "https") {
                throw new AppimgLinkError.INSECURE_URL(
                    _("Only https downloads are allowed, but this link points to %s.").printf(target.get_scheme() ?? "?"));
            }
            var target_host = target.get_host();
            if (target_host == null || target_host.strip() == "") {
                throw new AppimgLinkError.INVALID_LINK(_("The download URL in the install link has no host."));
            }

            var result = new AppimgLink();
            result.url = download_url;
            result.host = target_host;
            result.name = clean_text(params.lookup("name"));
            result.version = clean_text(params.lookup("version"));
            result.filename = derive_filename(target.get_path());

            var raw_sha256 = params.lookup("sha256");
            if (raw_sha256 != null && raw_sha256.strip() != "") {
                var digest = raw_sha256.strip().down();
                if (digest.length != 64 || !is_hex(digest)) {
                    throw new AppimgLinkError.INVALID_LINK(
                        _("The install link carries a malformed SHA-256 checksum."));
                }
                result.sha256 = digest;
            }

            var raw_size = params.lookup("size");
            if (raw_size != null && raw_size.strip() != "") {
                int64 declared;
                if (!int64.try_parse(raw_size.strip(), out declared) || declared <= 0) {
                    throw new AppimgLinkError.INVALID_LINK(_("The install link carries a malformed size."));
                }
                result.size = declared;
            }

            return result;
        }

        /**
         * Downloads into `dest_dir`, enforcing the declared size and checksum.
         * Blocking: callers run it on a worker thread and poll
         * received_bytes/total_bytes for progress.
         */
        public string download(string dest_dir, GLib.Cancellable? cancellable) throws Error {
            var dest_path = Path.build_filename(dest_dir, filename);
            received_bytes = 0;
            total_bytes = size;

            var session = new Soup.Session();
            session.user_agent = "AppManager/%s".printf(APPLICATION_VERSION);
            session.timeout = 60;

            try {
                TlsSession.with_session(() => {
                    var message = new Soup.Message("GET", url);
                    message.request_headers.replace("Accept", "application/octet-stream");

                    var input = session.send(message, cancellable);
                    var status = message.get_status();
                    if (status < 200 || status >= 300) {
                        throw new IOError.FAILED(_("Download failed (HTTP %u)").printf(status));
                    }

                    if (total_bytes <= 0) {
                        var announced = message.response_headers.get_content_length();
                        total_bytes = announced > 0 ? announced : -1;
                    }

                    var output = File.new_for_path(dest_path).replace(
                        null, false, FileCreateFlags.REPLACE_DESTINATION, cancellable);
                    var checksum = new Checksum(ChecksumType.SHA256);
                    uint8[] buffer = new uint8[64 * 1024];
                    ssize_t read;
                    while ((read = input.read(buffer, cancellable)) > 0) {
                        received_bytes += read;
                        if (size > 0 && received_bytes > size) {
                            throw new AppimgLinkError.SIZE_MISMATCH(
                                _("The download is larger than the install link declared."));
                        }
                        checksum.update(buffer, (size_t)read);
                        output.write(buffer[0:read], cancellable);
                    }
                    output.close(cancellable);
                    input.close(cancellable);

                    if (size > 0 && received_bytes != size) {
                        throw new AppimgLinkError.SIZE_MISMATCH(
                            _("The download is smaller than the install link declared."));
                    }
                    if (sha256 != null && checksum.get_string() != sha256) {
                        throw new AppimgLinkError.CHECKSUM_MISMATCH(
                            _("The downloaded file does not match the checksum in the install link."));
                    }
                });
            } catch (Error e) {
                try {
                    var partial = File.new_for_path(dest_path);
                    if (partial.query_exists()) {
                        partial.delete(null);
                    }
                } catch (Error cleanup_error) {
                    warning("Failed to remove partial download %s: %s", dest_path, cleanup_error.message);
                }
                throw e;
            }

            return dest_path;
        }

        private static bool is_hex(string value) {
            for (int i = 0; i < value.length; i++) {
                if (!value[i].isxdigit()) {
                    return false;
                }
            }
            return true;
        }

        /**
         * Strips control characters and clamps the length; link text is only
         * ever shown to the user, never used as a path.
         */
        private static string? clean_text(string? value) {
            if (value == null) {
                return null;
            }
            var builder = new StringBuilder();
            int index = 0;
            int kept = 0;
            unichar c;
            while (value.get_next_char(ref index, out c) && kept < 96) {
                if (c.iscntrl()) {
                    continue;
                }
                builder.append_unichar(c);
                kept++;
            }
            var cleaned = builder.str.strip();
            return cleaned.length > 0 ? cleaned : null;
        }

        /**
         * Rebuilds a safe file name from the URL path: no separators, no
         * dotfiles, always .AppImage.
         */
        private static string derive_filename(string? url_path) {
            var candidate = url_path != null ? Path.get_basename(url_path) : "";
            var builder = new StringBuilder();
            for (int i = 0; i < candidate.length; i++) {
                var c = candidate[i];
                if (c.isalnum() || c == '.' || c == '_' || c == '+' || c == '-') {
                    builder.append_c(c);
                }
            }
            var cleaned = builder.str;
            while (cleaned.has_prefix(".")) {
                cleaned = cleaned.substring(1);
            }
            if (cleaned.length > 128) {
                cleaned = cleaned.substring(cleaned.length - 128);
            }
            if (cleaned.length == 0) {
                cleaned = "download";
            }
            if (!cleaned.down().has_suffix(".appimage")) {
                cleaned += ".AppImage";
            }
            return cleaned;
        }
    }
}
