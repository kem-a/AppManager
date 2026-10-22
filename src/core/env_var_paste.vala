namespace AppManager.Core {
    public struct EnvAssignment {
        public string name;
        public string value;
    }

    // Parses copied launch settings, without shell expansion or command execution.
    public class EnvVarPaste : Object {
        public static bool looks_like_assignment(string text) {
            // A typed '=' must remain an ordinary keystroke.
            return text.length > 1 && text.index_of_char('=') >= 0;
        }

        public static EnvAssignment[] parse(string text) {
            EnvAssignment[] assignments = {};
            foreach (var raw_line in text.split("\n")) {
                var line = raw_line.has_suffix("\r")
                    ? raw_line.substring(0, raw_line.length - 1) : raw_line;
                if (line.strip().has_prefix("#")) continue;
                var eq = line.index_of_char('=');
                if (eq < 0) continue;
                var name = line.substring(0, eq).chug();
                if (name.has_prefix("export ")) name = name.substring(7);
                name = name.strip();
                if (name == "") continue;
                EnvAssignment assignment = { name, unquote(line.substring(eq + 1).chug()) };
                assignments += assignment;
            }
            return assignments;
        }

        private static string unquote(string value) {
            if (value.length < 2) return value;
            var quote = value[0];
            if ((quote == '"' || quote == '\'') && value[value.length - 1] == quote) {
                return value.substring(1, value.length - 2);
            }
            return value;
        }
    }
}
