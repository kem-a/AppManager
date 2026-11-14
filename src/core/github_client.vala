namespace AppManager.Core {
    /** Required JSON fields must fail as errors, not GLib criticals or empty matches. */
    public class SubmissionJson {
        public static Json.Object object(Json.Node? node) throws Error {
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA(_("Expected a JSON object in submission data."));
            return node.get_object();
        }
        public static Json.Node member(Json.Object obj, string key) throws Error {
            if (!obj.has_member(key)) throw new IOError.INVALID_DATA(_("Missing submission field: %s").printf(key));
            return obj.get_member(key);
        }
        public static Json.Object child(Json.Object obj, string key) throws Error { return object(member(obj, key)); }
        public static Json.Array array(Json.Node? node) throws Error {
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) throw new IOError.INVALID_DATA(_("Expected a JSON array in submission data."));
            return node.get_array();
        }
        public static string text(Json.Object obj, string key) throws Error {
            var node = member(obj, key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string) || node.get_string() == "")
                throw new IOError.INVALID_DATA(_("Invalid submission field: %s").printf(key));
            return node.get_string();
        }
        public static bool boolean(Json.Object obj, string key, bool fallback = false) throws Error {
            if (!obj.has_member(key)) return fallback;
            var node = obj.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(bool))
                throw new IOError.INVALID_DATA(_("Invalid submission field: %s").printf(key));
            return node.get_boolean();
        }
        public static int64 integer(Json.Object obj, string key) throws Error {
            var node = member(obj, key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(int64))
                throw new IOError.INVALID_DATA(_("Invalid submission field: %s").printf(key));
            return node.get_int();
        }
    }
    public class GitHubReply : Object {
        public uint status;
        public Json.Node body;
        public string scopes = "";
        public int64 requests_remaining = -1;
        public int64 requests_limit = -1;
        public GitHubReply(uint status, Json.Node body) {
            this.status = status;
            this.body = body;
        }

        public void read_rate_limit(Soup.MessageHeaders headers) {
            requests_remaining = header_number(headers, "X-RateLimit-Remaining");
            requests_limit = header_number(headers, "X-RateLimit-Limit");
        }

        private static int64 header_number(Soup.MessageHeaders headers, string key) {
            var text = headers.get_one(key);
            int64 value = -1;
            return text != null && int64.try_parse(text, out value) && value >= 0 ? value : -1;
        }

        public string usage_summary() {
            if (requests_remaining < 0 || requests_limit < 0) return "";
            return _("Token is valid — %s / %s requests remaining").printf(requests_remaining.to_string(), requests_limit.to_string());
        }
    }

    // Injectable transport keeps workflow tests off the network and away from real accounts.
    public delegate GitHubReply GitHubTransport(string method, string path, string? body, Cancellable? cancel) throws Error;

    public class GitHubClient : Object {
        private string token;
        private GitHubTransport? transport;
        private string? enabled_key;
        public GitHubClient(string token, owned GitHubTransport? transport = null, string? enabled_key = null) {
            this.token = token;
            this.transport = (owned) transport;
            this.enabled_key = enabled_key;
        }

        public static string json(Json.Node node) {
            var generator = new Json.Generator();
            generator.set_root(node);
            return generator.to_data(null);
        }

        // AppHub CI runs Prettier with this width; submitted manifests must match.
        private const int APPHUB_JSON_WIDTH = 100;

        /**
         * Human-readable JSON with two-space indentation and standard `"key": value`
         * spacing. Json.Generator's pretty mode puts a space before the colon, which
         * is valid but not what the AppHub catalog uses, so objects are written here.
         * Arrays of scalars stay on one line when they fit AppHub's print width;
         * Prettier collapses those, and objects stay expanded.
         */
        public static string pretty_json(Json.Node node) {
            var builder = new StringBuilder();
            pretty_write(builder, node, 0, 0);
            return builder.str;
        }

        private static void pretty_indent(StringBuilder builder, int depth) {
            for (int i = 0; i < depth * 2; i++) builder.append_c(' ');
        }

        private static void pretty_scalar(StringBuilder builder, Json.Node node) {
            var generator = new Json.Generator();
            generator.set_root(node);
            var data = generator.to_data(null);
            if (data != null) builder.append(data);
        }

        private static bool is_scalar(Json.Node? node) {
            return node == null || node.is_null() || node.get_node_type() == Json.NodeType.VALUE;
        }

        /** `column` is the number of characters already written on the current line. */
        private static void pretty_write(StringBuilder builder, Json.Node? node, int depth, int column) {
            if (node == null || node.is_null()) {
                builder.append("null");
                return;
            }
            switch (node.get_node_type()) {
                case Json.NodeType.OBJECT:
                    var obj = node.get_object();
                    var members = new Gee.ArrayList<string>();
                    foreach (var member in obj.get_members()) members.add(member);
                    if (members.size == 0) {
                        builder.append("{}");
                        return;
                    }
                    builder.append("{\n");
                    for (int i = 0; i < members.size; i++) {
                        pretty_indent(builder, depth + 1);
                        var key = new Json.Node(Json.NodeType.VALUE);
                        key.set_string(members[i]);
                        var key_text = new StringBuilder();
                        pretty_scalar(key_text, key);
                        builder.append(key_text.str);
                        builder.append(": ");
                        int value_column = (depth + 1) * 2 + key_text.str.char_count() + 2;
                        pretty_write(builder, obj.get_member(members[i]), depth + 1, value_column);
                        if (i + 1 < members.size) builder.append_c(',');
                        builder.append_c('\n');
                    }
                    pretty_indent(builder, depth);
                    builder.append_c('}');
                    break;
                case Json.NodeType.ARRAY:
                    var array = node.get_array();
                    int length = (int) array.get_length();
                    if (length == 0) {
                        builder.append("[]");
                        return;
                    }
                    bool scalars_only = true;
                    foreach (var element in array.get_elements()) {
                        if (!is_scalar(element)) {
                            scalars_only = false;
                            break;
                        }
                    }
                    if (scalars_only) {
                        var flat = new StringBuilder();
                        flat.append_c('[');
                        int index = 0;
                        foreach (var element in array.get_elements()) {
                            if (index++ > 0) flat.append(", ");
                            if (element == null || element.is_null()) flat.append("null");
                            else pretty_scalar(flat, element);
                        }
                        flat.append_c(']');
                        if (column + flat.str.char_count() <= APPHUB_JSON_WIDTH) {
                            builder.append(flat.str);
                            return;
                        }
                    }
                    builder.append("[\n");
                    int index = 0;
                    foreach (var element in array.get_elements()) {
                        pretty_indent(builder, depth + 1);
                        pretty_write(builder, element, depth + 1, (depth + 1) * 2);
                        if (++index < length) builder.append_c(',');
                        builder.append_c('\n');
                    }
                    pretty_indent(builder, depth);
                    builder.append_c(']');
                    break;
                default:
                    pretty_scalar(builder, node);
                    break;
            }
        }

        public GitHubReply request(string method, string path, Json.Node? body = null, Cancellable? cancel = null) throws Error {
            if (!path.has_prefix("/") || path.has_prefix("//") || path.contains("://"))
                throw new IOError.INVALID_ARGUMENT("Invalid GitHub API path");
            cancel_check(cancel);
            if (enabled_key != null && !new GLib.Settings(APPLICATION_ID).get_boolean(enabled_key))
                throw new IOError.CANCELLED(_("GitHub token use is disabled in Preferences."));
            if (transport != null) return transport(method, path, body == null ? null : json(body), cancel);
            var session = new Soup.Session();
            session.timeout = 30;
            session.user_agent = "AppManager/" + APPLICATION_VERSION;
            var message = new Soup.Message(method, "https://api.github.com" + path);
            // Never forward the token to a redirect destination.
            message.set_flags(Soup.MessageFlags.NO_REDIRECT);
            message.request_headers.replace("Authorization", "Bearer " + token);
            message.request_headers.replace("Accept", "application/vnd.github+json");
            message.request_headers.replace("X-GitHub-Api-Version", "2022-11-28");
            if (body != null) message.set_request_body_from_bytes("application/json", new Bytes(json(body).data));
            Json.Node? parsed = null;
            TlsSession.with_session(() => {
                var input = session.send(message, cancel);
                var output = new MemoryOutputStream.resizable();
                uint8[] buffer = new uint8[16384];
                ssize_t count;
                size_t total = 0;
                while ((count = input.read(buffer, cancel)) > 0) {
                    total += count;
                    if (total > 8 * 1024 * 1024) throw new IOError.FAILED(_("GitHub response is too large."));
                    output.write_all(buffer[0:count], null, cancel);
                }
                input.close(cancel);
                output.close(cancel);
                var parser = new Json.Parser();
                parser.load_from_stream(new MemoryInputStream.from_bytes(output.steal_as_bytes()), cancel);
                parsed = parser.get_root().copy();
            });
            var reply = new GitHubReply(message.status_code, parsed);
            reply.scopes = message.response_headers.get_one("X-OAuth-Scopes") ?? "";
            reply.read_rate_limit(message.response_headers);
            return reply;
        }

        public Json.Node require(string method, string path, Json.Node? body = null, Cancellable? cancel = null) throws Error {
            var reply = request(method, path, body, cancel);
            if (reply.status < 200 || reply.status >= 300) fail_status(reply.status);
            return reply.body;
        }

        public static void cancel_check(Cancellable? cancel) throws Error {
            if (cancel != null) cancel.set_error_if_cancelled();
        }

        public static void fail_status(uint status) throws Error {
            if (status == 401) throw new IOError.PERMISSION_DENIED(_("GitHub token is invalid or expired. Test the corresponding token again in Preferences."));
            if (status == 403 || status == 429) throw new IOError.PERMISSION_DENIED(_("GitHub denied access or its rate limit was reached. Check token permissions and try again later."));
            throw new IOError.FAILED(_("GitHub request failed (HTTP %u). Please retry.").printf(status));
        }

        public static string authenticate(GitHubReply reply, bool submission = false) throws Error {
            if (reply.status != 200) fail_status(reply.status);
            var login = SubmissionJson.text(SubmissionJson.object(reply.body), "login");
            if (!Regex.match_simple("^[A-Za-z0-9][A-Za-z0-9-]*$", login))
                throw new IOError.INVALID_DATA(_("GitHub did not return a valid account."));
            if (submission && !submission_scope(reply.scopes))
                throw new IOError.PERMISSION_DENIED(_("AppHub submissions require a classic GitHub token with public_repo scope (or repo scope)."));
            return login;
        }

        public static bool submission_scope(string scopes) {
            foreach (var scope in scopes.split(",")) if (scope.strip() == "public_repo" || scope.strip() == "repo") return true;
            return false;
        }
    }

    /** Independent, session-only verification for updates and AppHub submissions. */
    public class GitHubAuth : Object {
        private static GitHubAuth? updates_instance;
        private static GitHubAuth? apphub_instance;
        private bool submissions;
        private GLib.Settings settings = new GLib.Settings(APPLICATION_ID);
        private string enabled_key;
        private Cancellable? verification_cancel;
        private uint generation;
        public bool ready { get; private set; }
        public bool checking { get; private set; }
        public string status { get; private set; default = ""; }
        public signal void changed();
        public bool enabled { get { return settings.get_boolean(enabled_key); } }

        private GitHubAuth(bool submissions) {
            this.submissions = submissions;
            enabled_key = submissions ? "apphub-token-enabled" : "github-token-enabled";
            settings.changed[enabled_key].connect(() => invalidate());
        }

        public static GitHubAuth get_updates() {
            if (updates_instance == null) updates_instance = new GitHubAuth(false);
            return updates_instance;
        }

        public static GitHubAuth get_apphub() {
            if (apphub_instance == null) apphub_instance = new GitHubAuth(true);
            return apphub_instance;
        }

        private string missing_token_status() {
            return submissions ? _("Save and test the dedicated AppHub token to enable submissions.")
                : _("Save and test a GitHub token for updates.");
        }

        public void invalidate() {
            generation++;
            if (verification_cancel != null) verification_cancel.cancel();
            ready = false;
            checking = false;
            status = enabled ? missing_token_status() : _("Token use is disabled.");
            changed();
        }

        public async void verify() {
            var token = !enabled ? null : submissions ? TokenStore.get_apphub_request_token() : TokenStore.get_token();
            yield verify_client(new GitHubClient(token ?? "", null, enabled_key), token != null && token != "");
        }

        internal async void verify_client(GitHubClient client, bool has_token = true) {
            if (verification_cancel != null) verification_cancel.cancel();
            var cancel = new Cancellable();
            verification_cancel = cancel;
            uint attempt = ++generation;
            ready = false;
            checking = enabled && has_token;
            status = !enabled ? _("Token use is disabled.") : checking ? _("Testing GitHub authentication…") : missing_token_status();
            changed();
            if (!checking) return;
            string result = "";
            bool allowed = false;
            SourceFunc callback = verify_client.callback;
            new Thread<void>("github-auth", () => {
                try {
                    var reply = client.request("GET", "/user", null, cancel);
                    var login = GitHubClient.authenticate(reply);
                    allowed = !submissions || GitHubClient.submission_scope(reply.scopes);
                    var usage = reply.usage_summary();
                    result = !submissions ? (usage != "" ? usage : _("Token is valid"))
                        : allowed ? _("Authenticated as %s — AppHub submissions available.").printf(login)
                        : _("Authenticated as %s. AppHub requires a classic token with public_repo scope.").printf(login);
                } catch (Error e) { result = e.message; }
                Idle.add((owned) callback);
            });
            yield;
            if (attempt != generation || !enabled || cancel.is_cancelled()) return;
            checking = false;
            ready = allowed;
            status = result;
            changed();
        }
    }
}
