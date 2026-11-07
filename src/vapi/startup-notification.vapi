[CCode (cheader_filename = "startup_notification.h")]
namespace AppManager.StartupNotification {
    [CCode (cname = "am_startup_notification_complete")]
    public void complete (string? startup_id, string? activation_token);
}
