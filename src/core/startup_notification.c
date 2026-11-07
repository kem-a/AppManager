#include "startup_notification.h"

#ifdef HAVE_WAYLAND

#include <errno.h>
#include <glib.h>
#include <poll.h>
#include <string.h>
#include <wayland-client.h>

/* gtk_shell1 v1's startup-completion request needs no surface. Keep this small
 * wire description private: we only use opcode 1 and the capabilities event,
 * never create a gtk_surface1. xdg_activation_v1 cannot complete a launch
 * without a surface, and GDK's notify_startup_complete is a no-op when that
 * protocol is available. A single-instance command-line relay has no surface.
 */
static const struct wl_message shell_requests[] = {
  { "get_gtk_surface", "no", NULL },
  { "set_startup_id", "?s", NULL },
  { "system_bell", "?o", NULL },
};
static const struct wl_message shell_events[] = {
  { "capabilities", "u", NULL },
};
static const struct wl_interface shell_interface = {
  "gtk_shell1", 1, G_N_ELEMENTS (shell_requests), shell_requests,
  G_N_ELEMENTS (shell_events), shell_events
};

static void
ignore_capabilities (void *data, struct wl_proxy *shell, uint32_t capabilities)
{
}

static void (*shell_listener[])(void) = {
  (void (*)(void)) ignore_capabilities
};

static void
handle_global (void *data, struct wl_registry *registry, uint32_t name,
               const char *interface, uint32_t version)
{
  struct wl_proxy **shell = data;

  if (*shell == NULL && strcmp (interface, shell_interface.name) == 0)
    {
      *shell = wl_registry_bind (registry, name, &shell_interface, 1);
      wl_proxy_add_listener (*shell, shell_listener, NULL);
    }
}

static void
ignore_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = {
  handle_global, ignore_global_remove
};

static void
sync_done (void *data, struct wl_callback *callback, uint32_t serial)
{
  *(gboolean *) data = TRUE;
}

static const struct wl_callback_listener sync_listener = { sync_done };

/* Cosmetic cleanup must never turn an unresponsive compositor into a hung
 * launcher. Both roundtrips share one short deadline. */
static gboolean
sync_before (struct wl_display *display, gint64 deadline)
{
  gboolean done = FALSE;
  struct wl_callback *callback = wl_display_sync (display);

  if (callback == NULL)
    return FALSE;
  wl_callback_add_listener (callback, &sync_listener, &done);

  while (!done)
    {
      struct pollfd fd = { wl_display_get_fd (display), POLLIN, 0 };
      gint64 remaining;
      int ready;

      if (wl_display_dispatch_pending (display) < 0 || done)
        break;
      if (wl_display_prepare_read (display) != 0)
        continue;
      if (wl_display_flush (display) < 0)
        {
          if (errno != EAGAIN)
            {
              wl_display_cancel_read (display);
              break;
            }
          fd.events |= POLLOUT;
        }
      remaining = deadline - g_get_monotonic_time ();
      if (remaining <= 0)
        {
          wl_display_cancel_read (display);
          break;
        }
      ready = poll (&fd, 1, (remaining + 999) / 1000);
      if (ready > 0 && (fd.revents & POLLIN))
        {
          if (wl_display_read_events (display) < 0)
            break;
        }
      else
        {
          wl_display_cancel_read (display);
          if (ready < 0 && errno == EINTR)
            continue;
          if (ready <= 0 || (fd.revents & (POLLERR | POLLHUP | POLLNVAL)))
            break;
        }
    }

  wl_callback_destroy (callback);
  return done;
}

void
am_startup_notification_complete (const char *startup_id,
                                  const char *activation_token)
{
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_proxy *shell = NULL;
  gint64 deadline;

  if ((!startup_id || !*startup_id) && (!activation_token || !*activation_token))
    return;

  deadline = g_get_monotonic_time () + 250 * G_TIME_SPAN_MILLISECOND;
  display = wl_display_connect (NULL);
  if (display == NULL)
    return;

  registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, &shell);
  if (sync_before (display, deadline) && shell != NULL)
    {
      if (startup_id && *startup_id)
        wl_proxy_marshal (shell, 1, startup_id);
      if (activation_token && *activation_token &&
          g_strcmp0 (activation_token, startup_id) != 0)
        wl_proxy_marshal (shell, 1, activation_token);
      sync_before (display, deadline);
    }

  if (shell != NULL)
    wl_proxy_destroy (shell);
  wl_registry_destroy (registry);
  wl_display_disconnect (display);
}

#else

void
am_startup_notification_complete (const char *startup_id,
                                  const char *activation_token)
{
}

#endif
