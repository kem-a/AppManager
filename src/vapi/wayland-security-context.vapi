/*
 * Vala bindings for the Wayland security-context helper
 * (src/core/wayland_security_context.c). Wayland protocol clients need
 * generated C, so the helper does the talking and exposes one call.
 */
[CCode (cheader_filename = "wayland_security_context.h")]
namespace AppManager.WaylandSecurityContext {
    [CCode (cname = "AM_WSC_CREATED")]
    public const int CREATED;
    [CCode (cname = "AM_WSC_UNSUPPORTED")]
    public const int UNSUPPORTED;
    [CCode (cname = "AM_WSC_FAILED")]
    public const int FAILED;

    /**
     * Creates a compositor-tagged Wayland socket at `socket_path`. Consumes
     * `close_fd`, which the compositor watches for hangup to know when to stop
     * accepting connections.
     */
    [CCode (cname = "am_wayland_security_context_create")]
    public int create (string socket_path, string engine, string app_id,
                       string instance_id, int close_fd);
}
