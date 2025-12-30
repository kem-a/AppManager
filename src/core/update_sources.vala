using Gee;

namespace AppManager.Core {
    public abstract class UpdateSource : Object {}

    public abstract class ReleaseSource : UpdateSource {
        public string? current_version { get; protected set; }
    }

    public class DirectUrlSource : UpdateSource {
        public string url { get; private set; }

        public DirectUrlSource(string url) {
            Object();
            this.url = url;
        }

        public static DirectUrlSource? parse(string url) {
            try {
                var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                var scheme = uri.get_scheme();
                if (scheme == null) return null;
                
                var normalized = scheme.down();
                if (normalized != "http" && normalized != "https") {
                    return null;
                }
                return new DirectUrlSource(url);
            } catch (Error e) {
                return null;
            }
        }
    }

    public class GithubSource : ReleaseSource {
        public string owner { get; private set; }
        public string repo { get; private set; }

        public GithubSource(string owner, string repo, string? current_version) {
            Object();
            this.owner = owner;
            this.repo = repo;
            this.current_version = current_version;
        }

        public static GithubSource? parse(string url, string? record_version) {
            try {
                var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                var host = uri.get_host();
                var path = uri.get_path();
                
                if (host == null || host.down() != "github.com") {
                    return null;
                }
                if (path == null) return null;

                var segments = tokenize_path(path);
                if (segments.length < 2) return null;

                return new GithubSource(segments[0], segments[1], VersionUtils.sanitize(record_version));
            } catch (Error e) {
                return null;
            }
        }

        public string releases_api_url() {
            return "https://api.github.com/repos/%s/%s/releases?per_page=10".printf(owner, repo);
        }
    }

    public class GitlabSource : ReleaseSource {
        private string scheme;
        private string host;
        private int port;
        private string project_path;

        public GitlabSource(string scheme, string host, int port, string project_path, string? current_version) {
            Object();
            this.scheme = scheme;
            this.host = host;
            this.port = port;
            this.project_path = project_path;
            this.current_version = current_version;
        }

        public static GitlabSource? parse(string url, string? record_version) {
            try {
                var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                var host = uri.get_host();
                var path = uri.get_path();
                var scheme = uri.get_scheme() ?? "https";
                var port = uri.get_port();
                
                if (host == null || path == null) return null;
                
                // Must be gitlab.com or contain "gitlab" in hostname
                var host_lower = host.down();
                if (!host_lower.contains("gitlab")) {
                    return null;
                }

                var segments = tokenize_path(path);
                if (segments.length < 2) return null;

                // Project path is everything in the URL (already normalized)
                var project_builder = new StringBuilder();
                for (int i = 0; i < segments.length; i++) {
                    if (i > 0) project_builder.append("/");
                    project_builder.append(segments[i]);
                }

                return new GitlabSource(scheme, host, port, project_builder.str, VersionUtils.sanitize(record_version));
            } catch (Error e) {
                return null;
            }
        }

        public string releases_api_url() {
            var builder = new StringBuilder();
            builder.append(scheme);
            builder.append("://");
            builder.append(host);
            if (port > 0 && !((scheme == "https" && port == 443) || (scheme == "http" && port == 80))) {
                builder.append(":%d".printf(port));
            }
            builder.append("/api/v4/projects/");
            builder.append(GLib.Uri.escape_string(project_path, null, true));
            builder.append("/releases?per_page=10");
            return builder.str;
        }
    }

    private static string[] tokenize_path(string path) {
        var parts = new ArrayList<string>();
        foreach (var segment in path.split("/")) {
            if (segment != null && segment.strip() != "") {
                parts.add(segment);
            }
        }
        return parts.to_array();
    }
}
