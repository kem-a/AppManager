namespace AppManager.Core {
    /**
     * Unified version comparison and sanitization utilities.
     * Consolidates version handling logic previously scattered across multiple files.
     */
    public class VersionUtils : Object {
        /**
         * Sanitizes a version string by extracting the numeric version portion.
         * Handles common patterns like:
         *   - "v1.2.3" → "1.2.3"
         *   - "desktop-v1.0" → "1.0"
         *   - "1.2.3-beta" → "1.2.3"
         *
         * @param value The raw version string (may include prefixes, suffixes)
         * @return The cleaned numeric version, or null if no version found
         */
        public static string? sanitize(string? value) {
            if (value == null) return null;
            
            var trimmed = value.strip();
            if (trimmed.length == 0) return null;

            // Skip leading channel prefix (e.g., "desktop-v1.0") to get version
            int start = 0;
            for (int i = 0; i < trimmed.length; i++) {
                char ch = trimmed[i];
                if (ch >= '0' && ch <= '9') {
                    start = i;
                    // Include preceding 'v' if present
                    if (i > 0 && (trimmed[i - 1] == 'v' || trimmed[i - 1] == 'V')) {
                        start = i - 1;
                    }
                    break;
                }
            }
            if (start > 0) {
                trimmed = trimmed.substring(start);
            }

            // Strip leading 'v' or 'V'
            if (trimmed.has_prefix("v") || trimmed.has_prefix("V")) {
                trimmed = trimmed.substring(1);
            }

            // Extract numeric version (digits and dots only)
            var builder = new StringBuilder();
            for (int i = 0; i < trimmed.length; i++) {
                char ch = trimmed[i];
                if ((ch >= '0' && ch <= '9') || ch == '.') {
                    builder.append_c(ch);
                } else {
                    break;
                }
            }

            var result = builder.len > 0 ? builder.str.strip() : null;
            return (result != null && result.length > 0) ? result : null;
        }

        /**
         * Compares two version strings.
         * Handles null values, strips prefixes, and compares numeric segments.
         *
         * @param left First version string
         * @param right Second version string
         * @return negative if left < right, 0 if equal, positive if left > right
         */
        public static int compare(string? left, string? right) {
            var a = sanitize(left);
            var b = sanitize(right);
            
            if (a == null && b == null) return 0;
            if (a == null) return -1;
            if (b == null) return 1;

            var left_parts = a.split(".");
            var right_parts = b.split(".");
            var max_parts = int.max(left_parts.length, right_parts.length);

            for (int i = 0; i < max_parts; i++) {
                var lv = i < left_parts.length ? int.parse(left_parts[i]) : 0;
                var rv = i < right_parts.length ? int.parse(right_parts[i]) : 0;
                if (lv != rv) {
                    return lv > rv ? 1 : -1;
                }
            }
            return 0;
        }
    }
}
