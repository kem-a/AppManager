#pragma once

/* Finish this launch's feedback after its supervised process has exited. */
void am_startup_notification_complete (const char *startup_id,
                                      const char *activation_token);
