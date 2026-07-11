/*
 * Tier-2 fallback crypto for the stored GitHub token.
 *
 * See crypto_shim.h for the threat model. In short: AES-256-GCM with a key
 * derived (HKDF-SHA256) from the host machine-id + uid. machine-id is not a
 * secret, so this is hardening/obfuscation that defeats config exfiltration,
 * not protection against a same-user local process.
 *
 * All crypto is GnuTLS; GLib is used for allocation, base64, and file I/O so
 * the returned strings interoperate with Vala (which frees with g_free()).
 */

#include "crypto_shim.h"

#include <glib.h>
#include <string.h>
#include <unistd.h>

#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>

#define AM_BLOB_PREFIX "AMTC1:"
#define AM_SALT_LEN    16
#define AM_NONCE_LEN   12
#define AM_TAG_LEN     16
#define AM_KEY_LEN     32
#define AM_HKDF_INFO   "github-token-v1"

/* Read and trim the host machine-id. Returns a g_malloc'd string or NULL. */
static char *
read_machine_id (void)
{
  const char *paths[] = { "/etc/machine-id", "/var/lib/dbus/machine-id" };

  for (guint i = 0; i < G_N_ELEMENTS (paths); i++)
    {
      char *contents = NULL;
      gsize len = 0;

      if (g_file_get_contents (paths[i], &contents, &len, NULL))
        {
          char *trimmed = g_strstrip (contents); /* trims in place */
          if (trimmed[0] != '\0')
            {
              char *id = g_strdup (trimmed);
              g_free (contents);
              return id;
            }
          g_free (contents);
        }
    }

  return NULL;
}

/*
 * Derive the 32-byte AES key from (machine-id : uid : app-id) and salt via
 * HKDF-SHA256 into key_out. Returns TRUE on success.
 */
static gboolean
derive_key (const guint8 *salt, gsize salt_len, guint8 key_out[AM_KEY_LEN])
{
  char *machine_id = read_machine_id ();
  if (machine_id == NULL)
    return FALSE;

  char *ikm_str = g_strdup_printf ("%s:%u:com.github.AppManager",
                                   machine_id, (guint) getuid ());
  g_free (machine_id);

  gnutls_datum_t ikm  = { (unsigned char *) ikm_str, (unsigned int) strlen (ikm_str) };
  gnutls_datum_t salt_d = { (unsigned char *) salt, (unsigned int) salt_len };
  gnutls_datum_t info = { (unsigned char *) AM_HKDF_INFO, (unsigned int) strlen (AM_HKDF_INFO) };

  guint8 prk[AM_KEY_LEN];
  int rc = gnutls_hkdf_extract (GNUTLS_MAC_SHA256, &ikm, &salt_d, prk);
  if (rc == 0)
    {
      gnutls_datum_t prk_d = { prk, AM_KEY_LEN };
      rc = gnutls_hkdf_expand (GNUTLS_MAC_SHA256, &prk_d, &info, key_out, AM_KEY_LEN);
    }

  gnutls_memset (prk, 0, sizeof (prk));
  gnutls_memset (ikm_str, 0, strlen (ikm_str));
  g_free (ikm_str);

  return rc == 0;
}

char *
am_crypto_encrypt (const char *plaintext)
{
  if (plaintext == NULL)
    return NULL;

  guint8 salt[AM_SALT_LEN];
  guint8 nonce[AM_NONCE_LEN];
  if (gnutls_rnd (GNUTLS_RND_KEY, salt, sizeof (salt)) != 0)
    return NULL;
  if (gnutls_rnd (GNUTLS_RND_KEY, nonce, sizeof (nonce)) != 0)
    return NULL;

  guint8 key[AM_KEY_LEN];
  if (!derive_key (salt, sizeof (salt), key))
    return NULL;

  gnutls_datum_t key_d = { key, AM_KEY_LEN };
  gnutls_aead_cipher_hd_t handle = NULL;
  if (gnutls_aead_cipher_init (&handle, GNUTLS_CIPHER_AES_256_GCM, &key_d) != 0)
    {
      gnutls_memset (key, 0, sizeof (key));
      return NULL;
    }

  gsize pt_len = strlen (plaintext);
  gsize ct_cap = pt_len + AM_TAG_LEN;
  guint8 *ct = g_malloc (ct_cap);
  size_t ct_len = ct_cap;
  int rc = gnutls_aead_cipher_encrypt (handle,
                                       nonce, sizeof (nonce),
                                       NULL, 0,
                                       AM_TAG_LEN,
                                       plaintext, pt_len,
                                       ct, &ct_len);
  gnutls_aead_cipher_deinit (handle);
  gnutls_memset (key, 0, sizeof (key));

  if (rc != 0)
    {
      g_free (ct);
      return NULL;
    }

  /* payload = salt(16) || nonce(12) || ciphertext || tag(16) */
  gsize payload_len = AM_SALT_LEN + AM_NONCE_LEN + ct_len;
  guint8 *payload = g_malloc (payload_len);
  memcpy (payload, salt, AM_SALT_LEN);
  memcpy (payload + AM_SALT_LEN, nonce, AM_NONCE_LEN);
  memcpy (payload + AM_SALT_LEN + AM_NONCE_LEN, ct, ct_len);
  g_free (ct);

  char *b64 = g_base64_encode (payload, payload_len);
  g_free (payload);

  char *blob = g_strconcat (AM_BLOB_PREFIX, b64, NULL);
  g_free (b64);
  return blob;
}

char *
am_crypto_decrypt (const char *blob)
{
  if (blob == NULL)
    return NULL;
  if (!g_str_has_prefix (blob, AM_BLOB_PREFIX))
    return NULL; /* version gate: reject anything but AMTC1: */

  gsize payload_len = 0;
  guchar *payload = g_base64_decode (blob + strlen (AM_BLOB_PREFIX), &payload_len);
  if (payload == NULL
      || payload_len < (gsize) (AM_SALT_LEN + AM_NONCE_LEN + AM_TAG_LEN))
    {
      g_free (payload);
      return NULL;
    }

  const guint8 *salt  = payload;
  const guint8 *nonce = payload + AM_SALT_LEN;
  const guint8 *ct    = payload + AM_SALT_LEN + AM_NONCE_LEN;
  gsize ct_len = payload_len - AM_SALT_LEN - AM_NONCE_LEN;

  guint8 key[AM_KEY_LEN];
  if (!derive_key (salt, AM_SALT_LEN, key))
    {
      g_free (payload);
      return NULL;
    }

  gnutls_datum_t key_d = { key, AM_KEY_LEN };
  gnutls_aead_cipher_hd_t handle = NULL;
  if (gnutls_aead_cipher_init (&handle, GNUTLS_CIPHER_AES_256_GCM, &key_d) != 0)
    {
      gnutls_memset (key, 0, sizeof (key));
      g_free (payload);
      return NULL;
    }

  gsize pt_cap = ct_len - AM_TAG_LEN;
  guint8 *pt = g_malloc (pt_cap + 1); /* +1 for the NUL terminator */
  size_t pt_len = pt_cap;
  int rc = gnutls_aead_cipher_decrypt (handle,
                                       nonce, AM_NONCE_LEN,
                                       NULL, 0,
                                       AM_TAG_LEN,
                                       ct, ct_len,
                                       pt, &pt_len);
  gnutls_aead_cipher_deinit (handle);
  gnutls_memset (key, 0, sizeof (key));
  g_free (payload);

  if (rc != 0) /* tamper, truncation, or wrong machine/user -> tag mismatch */
    {
      gnutls_memset (pt, 0, pt_cap);
      g_free (pt);
      return NULL;
    }

  pt[pt_len] = '\0';
  char *result = g_strndup ((const char *) pt, pt_len);
  gnutls_memset (pt, 0, pt_cap + 1);
  g_free (pt);
  return result;
}
