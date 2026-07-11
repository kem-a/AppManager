/*
 * Round-trip and tamper-rejection tests for the tier-2 crypto shim.
 *
 * The shim needs a host machine-id; where none exists the whole suite is
 * skipped (exit 77) rather than failed, matching the "tier 2 unavailable"
 * degradation path.
 */

#include "crypto_shim.h"

#include <glib.h>
#include <string.h>

#define PREFIX    "AMTC1:"
#define SALT_LEN  16
#define NONCE_LEN 12

static void
test_roundtrip (void)
{
  const char *secret = "ghp_ExampleToken_0123456789abcdef";
  char *blob = am_crypto_encrypt (secret);
  g_assert_nonnull (blob);
  g_assert_true (g_str_has_prefix (blob, PREFIX));

  char *out = am_crypto_decrypt (blob);
  g_assert_nonnull (out);
  g_assert_cmpstr (out, ==, secret);

  g_free (out);
  g_free (blob);
}

static void
test_tampered (void)
{
  char *blob = am_crypto_encrypt ("ghp_tamper_target");
  g_assert_nonnull (blob);

  gsize payload_len = 0;
  guchar *payload = g_base64_decode (blob + strlen (PREFIX), &payload_len);
  g_assert_cmpuint (payload_len, >, (guint) (SALT_LEN + NONCE_LEN));

  /* Flip one bit in the first ciphertext byte -> GCM tag must reject it. */
  payload[SALT_LEN + NONCE_LEN] ^= 0x01;

  char *b64 = g_base64_encode (payload, payload_len);
  char *tampered = g_strconcat (PREFIX, b64, NULL);

  char *out = am_crypto_decrypt (tampered);
  g_assert_null (out);

  g_free (b64);
  g_free (tampered);
  g_free (payload);
  g_free (blob);
}

static void
test_truncated (void)
{
  /* Payload far shorter than salt + nonce + tag. */
  g_assert_null (am_crypto_decrypt ("AMTC1:AAAA"));
}

static void
test_bad_prefix (void)
{
  char *blob = am_crypto_encrypt ("ghp_prefix_check");
  g_assert_nonnull (blob);

  /* Same base64 body under a different version prefix must be rejected. */
  char *bad = g_strconcat ("AMTC2:", blob + strlen (PREFIX), NULL);
  g_assert_null (am_crypto_decrypt (bad));

  g_free (bad);
  g_free (blob);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  /* No machine-id -> tier 2 is unavailable; skip rather than fail. */
  char *probe = am_crypto_encrypt ("probe");
  if (probe == NULL)
    {
      g_print ("no machine-id available; tier-2 crypto unavailable\n");
      return 77;
    }
  g_free (probe);

  g_test_add_func ("/crypto/roundtrip", test_roundtrip);
  g_test_add_func ("/crypto/tampered", test_tampered);
  g_test_add_func ("/crypto/truncated", test_truncated);
  g_test_add_func ("/crypto/bad-prefix", test_bad_prefix);

  return g_test_run ();
}
