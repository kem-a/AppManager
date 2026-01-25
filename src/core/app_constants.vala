namespace AppManager.Core {
    public const string APPLICATION_ID = "com.github.AppManager";
    public const string REGISTRY_FILENAME = "installations.json";
    public const string UPDATES_LOG_FILENAME = "updates.log";
    public const string STAGED_UPDATES_FILENAME = "staged-updates.json";
    public const string DATA_DIRNAME = "app-manager";
    public const string APPLICATIONS_DIRNAME = "Applications";
    public const string EXTRACTED_DIRNAME = ".installed";
    public const string SQUASHFS_ROOT_DIR = "squashfs-root";
    public const string LOCAL_BIN_DIRNAME = ".local/bin";

    // Background update daemon check frequency (in seconds). Default: 1 hour. One lightweight timestamp comparison
    public const uint DAEMON_CHECK_INTERVAL = 3600;
}
