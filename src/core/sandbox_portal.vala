namespace AppManager.Core {
    /**
     * Answers portal calls for a sandboxed app, in front of its session bus proxy.
     *
     * The app's bus socket is this one. Every connection is passed on to
     * xdg-dbus-proxy byte for byte, descriptors included, except the calls answered
     * here, which never reach the host. xdg-dbus-proxy can only allow or refuse a
     * call, and the host portal is no place for these: it sees the proxy, a host
     * process, and for a host app it writes any command line into a login entry.
     *
     * Answered: Background.RequestBackground, and reads of that interface's
     * version. The request becomes an entry in the app's private autostart folder,
     * which AppAutostart mirrors to the host with only its arguments. That is no
     * more than the app can do by writing the entry itself; apps built for Flatpak
     * ask the portal and write nothing.
     *
     * Everything else goes on unchanged, so a call that is not answered here is
     * still the proxy's to refuse. No fake Flatpak identity is involved.
     */
    public class SandboxPortal {
        private const string PORTAL_NAME = "org.freedesktop.portal.Desktop";
        private const string PORTAL_PATH = "/org/freedesktop/portal/desktop";
        private const string BACKGROUND = "org.freedesktop.portal.Background";
        // What is answered here is version 1; SetStatus came with 2.
        private const uint32 BACKGROUND_VERSION = 1;

        public string socket_path { get; private set; }

        private string upstream;
        private string record_id;
        private string home;
        private string? desktop_file;
        private Socket listener;
        private Cancellable cancellable = new Cancellable();
        private DBusConnection? host_bus = null;
        private Mutex host_bus_lock = Mutex();

        /**
         * Listens next to `proxy_socket`, which need not exist yet: it is connected to
         * when the app connects. Null when the socket cannot be set up; the app then
         * gets the proxy's socket and no portal answers, as before.
         */
        public static SandboxPortal? start(string proxy_socket, string record_id, SandboxManifest manifest) {
            var self = new SandboxPortal();
            self.upstream = proxy_socket;
            self.record_id = record_id;
            self.home = manifest.home;
            self.desktop_file = manifest.desktop_file;
            self.socket_path = proxy_socket + "-app";
            GLib.FileUtils.unlink(self.socket_path);
            try {
                self.listener = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
                self.listener.bind(new UnixSocketAddress(self.socket_path), false);
                self.listener.listen();
            } catch (Error e) {
                warning("Sandbox: cannot listen on %s: %s", self.socket_path, e.message);
                GLib.FileUtils.unlink(self.socket_path);
                return null;
            }
            new Thread<void>("portal", self.accept_connections);
            return self;
        }

        public void stop() {
            cancellable.cancel();
            GLib.FileUtils.unlink(socket_path);
        }

        private void accept_connections() {
            while (true) {
                Socket client;
                try {
                    client = listener.accept(cancellable);
                } catch (Error e) {
                    return;
                }
                try {
                    var bus = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
                    bus.connect(new UnixSocketAddress(upstream));
                    new Connection(this, client, bus).start();
                } catch (Error e) {
                    // The client is dropped with its socket; the next one may fare better.
                    debug("Sandbox: no bus for a portal connection: %s", e.message);
                }
            }
        }

        // The real portal's unique name. Clients drop a signal from anyone else, and
        // without a portal on the host they never ask, so nothing is answered then.
        private string? portal_owner() {
            host_bus_lock.lock();
            try {
                if (host_bus == null) {
                    host_bus = Bus.get_sync(BusType.SESSION);
                    host_bus.set_exit_on_close(false);
                }
                var reply = host_bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "GetNameOwner", new Variant("(s)", PORTAL_NAME),
                    new VariantType("(s)"), DBusCallFlags.NONE, 2000);
                string owner;
                reply.get("(s)", out owner);
                return owner;
            } catch (Error e) {
                debug("Sandbox: no portal on the session bus: %s", e.message);
                return null;
            } finally {
                host_bus_lock.unlock();
            }
        }

        /**
         * Handles `call` if it is one of ours. Returns the messages to send back to
         * the app, or null when the call is to go on to the proxy.
         */
        private Gee.ArrayList<DBusMessage>? answer(DBusMessage call, string client_name) {
            if (call.get_message_type() != DBusMessageType.METHOD_CALL
                || call.get_destination() != PORTAL_NAME || call.get_path() != PORTAL_PATH) {
                return null;
            }
            var body = call.get_body();
            var member = call.get_member();
            Variant? result = null;
            DBusMessage? response = null;
            if (call.get_interface() == BACKGROUND && member == "RequestBackground"
                && body != null && body.is_of_type(new VariantType("(sa{sv})"))) {
                result = request_background(body.get_child_value(1), client_name, out response);
            } else if (call.get_interface() == "org.freedesktop.DBus.Properties" && body != null) {
                // Clients read the version before the first call (zbus reads them all)
                // and give up when refused. Only for this interface: GTK 4 switches
                // to every portal whose version it can read.
                var version = new Variant.uint32(BACKGROUND_VERSION);
                if (member == "GetAll" && body.is_of_type(new VariantType("(s)"))
                    && body.get_child_value(0).get_string() == BACKGROUND) {
                    var all = new VariantBuilder(new VariantType("a{sv}"));
                    all.add("{sv}", "version", version);
                    result = new Variant("(a{sv})", all);
                } else if (member == "Get" && body.is_of_type(new VariantType("(ss)"))
                    && body.get_child_value(0).get_string() == BACKGROUND
                    && body.get_child_value(1).get_string() == "version") {
                    result = new Variant("(v)", version);
                }
            }
            if (result == null) {
                return null;
            }
            var portal = portal_owner();
            if (portal == null) {
                return null;
            }

            var messages = new Gee.ArrayList<DBusMessage>();
            if ((call.get_flags() & DBusMessageFlags.NO_REPLY_EXPECTED) == 0) {
                var reply = new DBusMessage.method_reply(call);
                reply.set_body(result);
                messages.add(reply);
            }
            if (response != null) {
                messages.add(response);
            }
            foreach (var message in messages) {
                message.set_sender(portal);
                message.set_destination(client_name);
            }
            return messages;
        }

        // Writes or removes the app's login entry. Returns the reply, the request
        // handle, and in `response` the signal that carries the outcome.
        private Variant request_background(Variant options, string client_name, out DBusMessage response) {
            bool autostart = false;
            options.lookup("autostart", "b", out autostart);
            string[] command = {};
            var requested = options.lookup_value("commandline", new VariantType("as"));
            if (requested != null) {
                command = requested.get_strv();
            }
            string? token = null;
            options.lookup("handle_token", "s", out token);
            if (token == null || !is_path_element(token)) {
                token = "appmanager%u".printf(Random.next_int());
            }
            var handle = "%s/request/%s/%s".printf(PORTAL_PATH, client_name.substring(1).replace(".", "_"), token);

            bool written = AppAutostart.set_portal_entry(home, autostart ? command : null);
            bool enabled = AppAutostart.sync(record_id, home, desktop_file) && autostart && written;

            var results = new VariantBuilder(new VariantType("a{sv}"));
            results.add("{sv}", "background", new Variant.boolean(true));
            results.add("{sv}", "autostart", new Variant.boolean(enabled));
            response = new DBusMessage.signal(handle, "org.freedesktop.portal.Request", "Response");
            // 0 is success, 2 "ended in some other way": what the portal itself answers.
            response.set_body(new Variant("(ua{sv})", (uint32) (written ? 0 : 2), results));
            return new Variant("(o)", handle);
        }

        private static bool is_path_element(string value) {
            if (value.length == 0 || value.length > 255) {
                return false;
            }
            for (int i = 0; i < value.length; i++) {
                if (!value[i].isalnum() && value[i] != '_') {
                    return false;
                }
            }
            return true;
        }

        /**
         * One client connection and its connection to the proxy, a thread for each
         * direction. Both streams are followed message by message.
         *
         * A call answered here is not simply dropped: a GetId call to the bus goes on
         * in its place, under the same serial, and the answer replaces the reply to
         * it. The answer is then in order with everything the app asked the bus
         * before, as the real portal's would be. Sent at once, a Response reaches a
         * client that subscribed by name before it knows who owns the name, and is
         * dropped (libportal).
         */
        private class Connection {
            // A call answered here is small. Anything bigger passes uninspected.
            private const size_t MAX_INSPECTED = 65536;
            private const size_t HEADER = 16;

            private SandboxPortal portal;
            private Socket client;
            private Socket bus;

            private Mutex state = Mutex();
            // The first message from the bus answers Hello with the app's bus name.
            private bool greeted = false;
            private string? client_name = null;
            // Answers by the serial of the call they replace.
            private Gee.HashMap<uint32, Bytes> held = new Gee.HashMap<uint32, Bytes>();
            private uint32 serial = 0x7f000000;

            public Connection(SandboxPortal portal, Socket client, Socket bus) {
                this.portal = portal;
                this.client = client;
                this.bus = bus;
            }

            public void start() {
                new Thread<void>("portal-in", () => { run(client, bus, true); });
                new Thread<void>("portal-out", () => { run(bus, client, false); });
            }

            private void run(Socket from, Socket to, bool from_client) {
                try {
                    relay(from, to, from_client);
                } catch (Error e) {
                    debug("Sandbox: portal connection closed: %s", e.message);
                }
                // Wakes the other direction, which then ends too.
                try { client.shutdown(true, true); } catch (Error e) {}
                try { bus.shutdown(true, true); } catch (Error e) {}
            }

            private static ssize_t receive(Socket from, uint8[] buffer, out SocketControlMessage[]? fds) throws Error {
                InputVector vector = InputVector() { buffer = (void*) buffer, size = buffer.length };
                int flags = 0;
                return from.receive_message(null, { vector }, out fds, ref flags, null);
            }

            private static void send(Socket to, uint8[] data, SocketControlMessage[]? fds = null) throws Error {
                size_t offset = 0;
                unowned SocketControlMessage[]? pending = fds;
                while (offset < data.length) {
                    OutputVector vector = OutputVector() { buffer = (void*) ((uint8*) data + offset), size = data.length - offset };
                    offset += (size_t) to.send_message(null, { vector }, pending, 0, null);
                    pending = null;
                }
            }

            private static SocketControlMessage[]? join(SocketControlMessage[]? first, SocketControlMessage[]? second) {
                if (first == null || first.length == 0) {
                    return second;
                }
                if (second == null || second.length == 0) {
                    return first;
                }
                var all = new SocketControlMessage[0];
                foreach (var message in first) {
                    all += message;
                }
                foreach (var message in second) {
                    all += message;
                }
                return all;
            }

            // Descriptors travel with the message they belong to: plain bytes are
            // collected and flushed before anything that carries descriptors.
            private static void forward(Socket to, ByteArray plain, uint8[] data, SocketControlMessage[]? fds) throws Error {
                if (fds == null || fds.length == 0) {
                    plain.append(data);
                    return;
                }
                flush(to, plain);
                send(to, data, fds);
            }

            private static void flush(Socket to, ByteArray plain) throws Error {
                if (plain.len > 0) {
                    send(to, plain.data);
                    plain.set_size(0);
                }
            }

            private void relay(Socket from, Socket to, bool from_client) throws Error {
                var buffer = new uint8[65536];
                // The text handshake comes first. The client ends it with a BEGIN
                // line; none of the server's lines starts with a message's first byte.
                bool handshake = true;
                var line = new StringBuilder();
                bool line_start = true;
                // The message being collected, its length once the header is in, and
                // the descriptors that came with its first part.
                var message = new ByteArray();
                size_t total = 0;
                SocketControlMessage[]? message_fds = null;
                // What is left of a message that passes uninspected.
                size_t passing = 0;

                while (true) {
                    SocketControlMessage[]? fds;
                    var got = receive(from, buffer, out fds);
                    if (got <= 0) {
                        return;
                    }
                    size_t end = got;
                    size_t offset = 0;
                    var plain = new ByteArray();

                    while (handshake && offset < end) {
                        var byte = buffer[offset];
                        if (!from_client) {
                            if (line_start && (byte == 'l' || byte == 'B')) {
                                handshake = false;
                                break;
                            }
                            line_start = byte == '\n';
                        } else {
                            if (line.len < 16) {
                                line.append_c((char) byte);
                            }
                            if (byte == '\n') {
                                handshake = line.str != "BEGIN\r\n";
                                line.truncate(0);
                            }
                        }
                        offset++;
                    }
                    plain.append(buffer[0:offset]);

                    while (offset < end) {
                        if (passing > 0) {
                            var take = size_t.min(passing, end - offset);
                            // Descriptors belong to the message the read ended in.
                            forward(to, plain, buffer[offset:offset + take], offset + take == end ? fds : null);
                            if (offset + take == end) {
                                fds = null;
                            }
                            passing -= take;
                            offset += take;
                            continue;
                        }
                        if (message.len < HEADER) {
                            var take = size_t.min(HEADER - message.len, end - offset);
                            message.append(buffer[offset:offset + take]);
                            offset += take;
                            if (message.len < HEADER) {
                                break;
                            }
                            total = (size_t) DBusMessage.bytes_needed(message.data);
                            if (total > MAX_INSPECTED || !(from_client || awaited(message.data[1]))) {
                                if (offset == end) {
                                    message_fds = join(message_fds, fds);
                                    fds = null;
                                }
                                forward(to, plain, message.data, message_fds);
                                message_fds = null;
                                passing = total - HEADER;
                                message.set_size(0);
                                continue;
                            }
                        }
                        var rest = size_t.min(total - message.len, end - offset);
                        message.append(buffer[offset:offset + rest]);
                        offset += rest;
                        if (message.len == total) {
                            if (offset == end) {
                                message_fds = join(message_fds, fds);
                                fds = null;
                            }
                            var other = from_client ? instead_of_call(message.data) : instead_of_reply(message.data);
                            if (other == null) {
                                forward(to, plain, message.data, message_fds);
                            } else if (other.get_size() > 0) {
                                plain.append(other.get_data());
                            }
                            message_fds = null;
                            message.set_size(0);
                        }
                    }
                    // The read ended inside a message still being collected.
                    message_fds = join(message_fds, fds);
                    flush(to, plain);
                }
            }

            // What to send the bus in place of `blob`, one whole message from the
            // app, when it is answered here. Null sends it on as it is.
            private Bytes? instead_of_call(uint8[] blob) {
                if (blob[1] != (uint8) DBusMessageType.METHOD_CALL || !contains(blob, BACKGROUND)) {
                    return null;
                }
                state.lock();
                var name = client_name;
                state.unlock();
                if (name == null) {
                    return null;
                }
                try {
                    var call = new DBusMessage.from_blob(blob, DBusCapabilityFlags.UNIX_FD_PASSING);
                    var messages = portal.answer(call, name);
                    if (messages == null) {
                        return null;
                    }
                    var answer = new ByteArray();
                    state.lock();
                    try {
                        foreach (var message in messages) {
                            message.set_serial(serial++);
                            answer.append(message.to_blob(DBusCapabilityFlags.NONE));
                        }
                        held[call.get_serial()] = new Bytes(answer.data);
                    } finally {
                        state.unlock();
                    }
                    var ping = new DBusMessage.method_call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", "GetId");
                    ping.set_serial(call.get_serial());
                    return new Bytes(ping.to_blob(DBusCapabilityFlags.NONE));
                } catch (Error e) {
                    debug("Sandbox: portal call not answered: %s", e.message);
                    return null;
                }
            }

            // Whether a message of this type from the bus has to be looked at whole.
            private bool awaited(uint8 type) {
                state.lock();
                bool wanted = !greeted || (held.size > 0 && (type == (uint8) DBusMessageType.METHOD_RETURN
                    || type == (uint8) DBusMessageType.ERROR));
                state.unlock();
                return wanted;
            }

            // The answer held for the call `blob` replies to, or null to send it on.
            private Bytes? instead_of_reply(uint8[] blob) {
                DBusMessage reply;
                try {
                    reply = new DBusMessage.from_blob(blob, DBusCapabilityFlags.NONE);
                } catch (Error e) {
                    return null;
                }
                state.lock();
                try {
                    if (!greeted) {
                        greeted = true;
                        var body = reply.get_body();
                        if (reply.get_message_type() == DBusMessageType.METHOD_RETURN
                            && body != null && body.is_of_type(new VariantType("(s)"))) {
                            var name = body.get_child_value(0).get_string();
                            if (name.has_prefix(":")) {
                                client_name = name;
                            }
                        }
                        return null;
                    }
                    Bytes? answer;
                    return held.unset(reply.get_reply_serial(), out answer) ? answer : null;
                } finally {
                    state.unlock();
                }
            }

            private static bool contains(uint8[] blob, string text) {
                unowned uint8[] wanted = text.data;
                for (size_t i = 0; i + wanted.length <= blob.length; i++) {
                    if (blob[i] == wanted[0] && Memory.cmp(&blob[i], wanted, wanted.length) == 0) {
                        return true;
                    }
                }
                return false;
            }
        }
    }
}
