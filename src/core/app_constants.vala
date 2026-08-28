namespace AppManager.Core {
    public const string APPLICATION_ID = "com.github.AppManager";
    public const string REGISTRY_FILENAME = "installations.json";
    public const string UPDATES_LOG_FILENAME = "updates.log";
    public const string STAGED_UPDATES_FILENAME = "staged-updates.json";
    public const string CUSTOM_VALUES_FILENAME = "custom.json";
    public const string DATA_DIRNAME = "app-manager";
    public const string APPLICATIONS_DIRNAME = "Applications";
    public const string EXTRACTED_DIRNAME = ".installed";
    public const string SQUASHFS_ROOT_DIR = "squashfs-root";
    public const string LOCAL_BIN_DEFAULT_DIRNAME = ".local/bin";

    // Sandbox profile names stored in InstallationRecord.sandbox_profile.
    public const string SANDBOX_PROFILE_OFF = "off";
    public const string SANDBOX_PROFILE_STANDARD = "standard";
    public const string SANDBOX_PROFILE_STRICT = "strict";
    public const string SANDBOX_PROFILE_CUSTOM = "custom";

    // Per-app sandbox manifests live in
    // <data_dir>/<SANDBOX_DIRNAME>/<record-id><SANDBOX_MANIFEST_SUFFIX>.
    public const string SANDBOX_DIRNAME = "sandbox";
    public const string SANDBOX_MANIFEST_SUFFIX = ".sandbox";

    // Manifest format revision. Bumped when a key's meaning changes; the launcher
    // refuses a manifest from a future version rather than guessing.
    public const int SANDBOX_MANIFEST_VERSION = 1;

    // Prefix of the generated per-app sandbox identity - the root of the app's D-Bus
    // names and its Wayland security-context app id, e.g.
    // io.appmanager.sandboxed.Inkscape.
    public const string SANDBOX_APP_ID_PREFIX = "io.appmanager.sandboxed";

    // Sandbox engine name reported to a Wayland compositor through
    // security-context-v1. Deliberately not "org.flatpak" - we are not flatpak.
    public const string SANDBOX_ENGINE_NAME = "io.appmanager";

    // CLI verb used by the generated .desktop Exec lines and bin wrappers to
    // re-enter AppManager as the sandbox launcher. See SandboxLauncher.
    public const string SANDBOX_RUN_VERB = "sandbox-run";

    // Background update daemon check frequency (in seconds). One lightweight
    // timestamp comparison per tick, so a short interval is cheap. Kept short
    // because GLib timers do not advance during suspend (issue #141).
    public const uint DAEMON_CHECK_INTERVAL = 600;

    // Delay (in seconds) after resume-from-suspend before attempting an update
    // check, giving the network time to reconnect.
    public const uint RESUME_CHECK_DELAY = 10;
}
