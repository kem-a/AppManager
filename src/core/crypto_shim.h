#ifndef AM_CRYPTO_SHIM_H
#define AM_CRYPTO_SHIM_H

/*
 * Tier-2 fallback crypto for the stored GitHub token (see token_store.vala).
 *
 * IMPORTANT: this is machine+user-bound obfuscation, NOT strong secrecy. The
 * AES key is derived from /etc/machine-id (which is not a secret) plus the
 * current uid. That makes a config file which is synced to the cloud, backed
 * up, or copied to another machine/account useless off its origin machine --
 * the realistic leak path. It does NOT protect against a process running as
 * the same user on the same machine: such a process can re-derive the exact
 * same key we do. Nothing user-space can prevent that.
 *
 * Both functions return a newly-allocated, NUL-terminated string that the
 * caller owns and must release with g_free(). A NULL return means failure:
 * missing machine-id (tier 2 unavailable), RNG failure, or -- for decrypt --
 * a wrong prefix, a truncated blob, tampering, or a wrong machine/user.
 */

char *am_crypto_encrypt (const char *plaintext);
char *am_crypto_decrypt (const char *blob);

#endif /* AM_CRYPTO_SHIM_H */
