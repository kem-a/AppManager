/*
 * Vala bindings for the tier-2 crypto shim (src/core/crypto_shim.c).
 * GnuTLS ships no Vala vapi, so the shim exposes a minimal C surface instead.
 */
[CCode (cheader_filename = "crypto_shim.h")]
namespace AppManager.Crypto {
    [CCode (cname = "am_crypto_encrypt")]
    public string? encrypt (string plaintext);

    [CCode (cname = "am_crypto_decrypt")]
    public string? decrypt (string blob);
}
