/*
 * Wayland security-context-v1: telling the compositor that a client is sandboxed.
 *
 * This is a different boundary from the portal identity and neither replaces the
 * other. xdg-desktop-portal does not read a security context, and a compositor
 * does not read /.flatpak-info; the portal decides what a *dialog* may grant,
 * while the compositor decides what the *Wayland connection* may do. Without a
 * security context, a sandboxed app can still bind screen-capture and
 * input-inhibiting protocols directly and never involve a portal at all.
 *
 * The mechanism: create a listening socket, hand it to the compositor along with
 * an identity, and bind that socket into the sandbox in place of the
 * compositor's own. Everything arriving through it is tagged.
 */

#include "wayland_security_context.h"

#ifdef HAVE_WAYLAND

#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#include "security-context-v1-client-protocol.h"

struct am_wsc_registry
{
  struct wp_security_context_manager_v1 *manager;
};

static void
handle_global (void *data, struct wl_registry *registry, uint32_t name,
               const char *interface, uint32_t version)
{
  struct am_wsc_registry *state = data;

  (void) version;
  if (strcmp (interface, wp_security_context_manager_v1_interface.name) == 0)
    state->manager = wl_registry_bind (registry, name,
                                       &wp_security_context_manager_v1_interface, 1);
}

static void
handle_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
  (void) data;
  (void) registry;
  (void) name;
}

static const struct wl_registry_listener registry_listener = {
  .global = handle_global,
  .global_remove = handle_global_remove,
};

/* A listening AF_UNIX socket at path, or -1. */
static int
open_listening_socket (const char *path)
{
  struct sockaddr_un addr;
  int fd;

  memset (&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  if (strlen (path) >= sizeof addr.sun_path)
    return -1;
  strcpy (addr.sun_path, path);

  fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0)
    return -1;

  /* A socket left behind by a supervisor that was killed would make bind fail. */
  unlink (path);

  if (bind (fd, (struct sockaddr *) &addr, sizeof addr) < 0 ||
      listen (fd, 128) < 0)
    {
      close (fd);
      unlink (path);
      return -1;
    }

  return fd;
}

int
am_wayland_security_context_create (const char *socket_path,
                                    const char *engine,
                                    const char *app_id,
                                    const char *instance_id,
                                    int close_fd)
{
  struct wl_display *display = NULL;
  struct wl_registry *registry = NULL;
  struct am_wsc_registry state = { NULL };
  struct wp_security_context_v1 *context = NULL;
  int listen_fd = -1;
  int result = AM_WSC_FAILED;

  display = wl_display_connect (NULL);
  if (display == NULL)
    {
      /* No compositor to talk to: there is no Wayland access to protect. */
      result = AM_WSC_UNSUPPORTED;
      goto out;
    }

  registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, &state);
  if (wl_display_roundtrip (display) < 0)
    goto out;

  if (state.manager == NULL)
    {
      result = AM_WSC_UNSUPPORTED;
      goto out;
    }

  listen_fd = open_listening_socket (socket_path);
  if (listen_fd < 0)
    goto out;

  /* Both descriptors are transferred to the compositor here; after this the only
   * valid thing left to do with them is close our copies. */
  context = wp_security_context_manager_v1_create_listener (state.manager,
                                                            listen_fd, close_fd);
  if (context == NULL)
    goto out;

  wp_security_context_v1_set_sandbox_engine (context, engine);
  wp_security_context_v1_set_app_id (context, app_id);
  wp_security_context_v1_set_instance_id (context, instance_id);
  wp_security_context_v1_commit (context);

  /* The roundtrip is what turns a protocol error — an engine name the compositor
   * refuses, a duplicate identity — into a failure here rather than a silently
   * untagged socket. */
  if (wl_display_roundtrip (display) < 0)
    goto out;

  result = AM_WSC_CREATED;

out:
  if (context != NULL)
    wp_security_context_v1_destroy (context);
  if (state.manager != NULL)
    wp_security_context_manager_v1_destroy (state.manager);
  if (registry != NULL)
    wl_registry_destroy (registry);
  if (display != NULL)
    {
      wl_display_flush (display);
      wl_display_disconnect (display);
    }
  if (listen_fd >= 0)
    close (listen_fd);
  if (close_fd >= 0)
    close (close_fd);
  if (result != AM_WSC_CREATED)
    unlink (socket_path);

  return result;
}

#else /* !HAVE_WAYLAND */

#include <unistd.h>

int
am_wayland_security_context_create (const char *socket_path,
                                    const char *engine,
                                    const char *app_id,
                                    const char *instance_id,
                                    int close_fd)
{
  (void) socket_path;
  (void) engine;
  (void) app_id;
  (void) instance_id;
  if (close_fd >= 0)
    close (close_fd);
  return AM_WSC_UNSUPPORTED;
}

#endif /* HAVE_WAYLAND */
