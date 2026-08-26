using Gee;

namespace AppManager.Core {
    /**
     * Implements the "sandbox-run" CLI verb that generated .desktop Exec lines and
     * ~/.local/bin wrappers use to launch a sandboxed app:
     *
     *   app-manager sandbox-run --id=<record-id> --target=<path> [-- <app args>]
     *
     * Routing every launch through one verb keeps the Exec lines short and means a
     * permission change rewrites a single .args file instead of the primary Exec,
     * every desktop action and every sub-entry.
     *
     * --target is the path the Exec would have held without the sandbox: the AppImage
     * for the main entry, or the ~/.local/bin symlink for a sub-entry of a
     * multi-component AppImage. sas resolves it and passes the unresolved spelling on
     * as ARGV0, which is what the AppImage runtime dispatches components on — so the
     * component a sub-entry asked for is the one that starts.
     *
     * This runs before GApplication is constructed (see main.vala): AppManager
     * registers as a single instance, so a normal command line would be forwarded to
     * the already-running GUI and this process would exit immediately, leaving the
     * app it launched with no parent to be tied to.
     *
     * Exit codes: 2 for a malformed invocation, 3 when the app is configured to be
     * sandboxed but sas is unavailable, 127 when exec itself fails.
     */
    public class SandboxLauncher {
        /**
         * Parses the sandbox-run argument list and execs the app. Only returns on
         * failure — on success this process is replaced.
         */
        public static int run(string[] args) {
            string? record_id = null;
            string? target = null;
            var app_args = new ArrayList<string>();
            bool after_separator = false;

            // args[0] is the binary, args[1] is the verb itself.
            for (int i = 2; i < args.length; i++) {
                var arg = args[i];
                if (after_separator) {
                    app_args.add(arg);
                    continue;
                }
                if (arg == "--") {
                    after_separator = true;
                } else if (arg.has_prefix("--id=")) {
                    record_id = arg.substring("--id=".length);
                } else if (arg.has_prefix("--target=")) {
                    target = arg.substring("--target=".length);
                } else {
                    // Tolerate a caller that forgot the separator.
                    app_args.add(arg);
                }
            }

            if (target == null || target.strip() == "") {
                printerr("%s: --target is required\n", SANDBOX_RUN_VERB);
                return 2;
            }
            target = target.strip();

            var sas = AppPaths.sas_path;
            string[]? flags = (record_id != null && record_id.strip() != "")
                ? SandboxConfig.read_args_file(record_id.strip())
                : null;

            // No profile on disk means this app is not sandboxed any more and only its
            // Exec line is stale — launching it plainly is what the user asked for.
            if (flags == null) {
                return exec(target, new ArrayList<string>(), app_args);
            }

            // A profile exists but sas does not. Refuse: the user configured this app to
            // be contained, and starting it unconfined while they believe otherwise is
            // worse than not starting it. AppManager's own UI reports sas as missing.
            if (sas == null) {
                printerr("%s: %s is configured to run sandboxed, but sas was not found.\n",
                    SANDBOX_RUN_VERB, target);
                printerr("%s: install simple-appimage-sandbox, or turn the sandbox off for this app.\n",
                    SANDBOX_RUN_VERB);
                return 3;
            }

            // sas takes its flags first, then the app to launch.
            var sas_args = new ArrayList<string>();
            foreach (var flag in flags) {
                sas_args.add(flag);
            }
            sas_args.add(target);
            return exec(sas, sas_args, app_args);
        }

        /**
         * Replaces this process with `program`, passing `leading_args` then the app's
         * own arguments. Returns an exit status only if exec fails.
         */
        private static int exec(string program, ArrayList<string> leading_args, ArrayList<string> app_args) {
            var argv = new string[leading_args.size + app_args.size + 2];
            int n = 0;
            argv[n++] = program;
            foreach (var arg in leading_args) {
                argv[n++] = arg;
            }
            foreach (var app_arg in app_args) {
                argv[n++] = app_arg;
            }
            argv[n] = null;

            Posix.execvp(program, argv);
            // Only reached when exec itself failed.
            printerr("%s: failed to exec %s: %s\n",
                SANDBOX_RUN_VERB, program, Posix.strerror(Posix.errno));
            return 127;
        }
    }
}
