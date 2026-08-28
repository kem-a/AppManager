#ifndef AM_WAYLAND_SECURITY_CONTEXT_H
#define AM_WAYLAND_SECURITY_CONTEXT_H

/* Return values of am_wayland_security_context_create. */
#define AM_WSC_CREATED     0  /* the compositor accepted the security context */
#define AM_WSC_UNSUPPORTED 1  /* the compositor does not offer the protocol */
#define AM_WSC_FAILED     -1  /* the protocol is offered but setup failed */

/**
 * Creates a Wayland socket at socket_path that the compositor will treat as a
 * sandboxed client's, tagged with the given sandbox engine, app id and instance
 * id. The sandbox binds that socket instead of the compositor's own, and the
 * compositor then refuses the privileged protocols — screen capture, input
 * inhibiting, virtual input — to whatever connects through it.
 *
 * close_fd is consumed: it is handed to the compositor, which stops accepting
 * connections on the socket once it signals hangup, and this function closes its
 * own copy either way. Pass the read end of a pipe whose write end the caller
 * holds for as long as the app should be able to connect.
 *
 * AM_WSC_UNSUPPORTED means "bind the compositor's socket as before".
 * AM_WSC_FAILED must be treated as fatal for Wayland access: the compositor
 * offered to sandbox this client and something went wrong, so falling back to
 * the raw socket would silently hand over the privileged protocols instead.
 */
int am_wayland_security_context_create (const char *socket_path,
                                        const char *engine,
                                        const char *app_id,
                                        const char *instance_id,
                                        int close_fd);

#endif /* AM_WAYLAND_SECURITY_CONTEXT_H */
