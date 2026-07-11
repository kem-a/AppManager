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

    // Background update daemon check frequency (in seconds). One lightweight
    // timestamp comparison per tick, so a short interval is cheap. Kept short
    // because GLib timers do not advance during suspend (issue #141).
    public const uint DAEMON_CHECK_INTERVAL = 600;

    // Delay (in seconds) after resume-from-suspend before attempting an update
    // check, giving the network time to reconnect.
    public const uint RESUME_CHECK_DELAY = 10;
}
