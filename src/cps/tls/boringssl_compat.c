/*
 * BoringSSL compatibility shims for Nim's std/openssl and our TLS code.
 *
 * BoringSSL doesn't export SSL_CTX_ctrl / SSL_ctrl (OpenSSL generic dispatch).
 * Nim's std/openssl uses SSL_ctrl for SSL_set_tlsext_host_name.
 * We provide minimal implementations that call the real BoringSSL functions.
 *
 * BoringSSL also doesn't have SSL_CTX_set_ciphersuites (TLS 1.3 suites are
 * part of the regular cipher list via SSL_CTX_set_cipher_list).
 */

#include <openssl/ssl.h>
#include <openssl/aead.h>
#include <openssl/chacha.h>
#include <string.h>

/* SSL_CTRL_SET_TLSEXT_HOSTNAME = 55 in OpenSSL */
#define COMPAT_SSL_CTRL_SET_TLSEXT_HOSTNAME 55
/* SSL_CTRL_SET_MIN_PROTO_VERSION = 123, SSL_CTRL_SET_MAX_PROTO_VERSION = 124 */
#define COMPAT_SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define COMPAT_SSL_CTRL_SET_MAX_PROTO_VERSION 124

long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg) {
    switch (cmd) {
        case COMPAT_SSL_CTRL_SET_MIN_PROTO_VERSION:
            return SSL_CTX_set_min_proto_version(ctx, (uint16_t)larg);
        case COMPAT_SSL_CTRL_SET_MAX_PROTO_VERSION:
            return SSL_CTX_set_max_proto_version(ctx, (uint16_t)larg);
        default:
            return 0;
    }
}

long SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg) {
    switch (cmd) {
        case COMPAT_SSL_CTRL_SET_TLSEXT_HOSTNAME:
            SSL_set_tlsext_host_name(ssl, (const char *)parg);
            return 1;
        default:
            return 0;
    }
}

/* BoringSSL doesn't separate TLS 1.3 ciphersuites — they're set via
 * SSL_CTX_set_cipher_list. This stub ignores the call (suites are already
 * configured via cipherList). Returns 1 (success). */
int SSL_CTX_set_ciphersuites(SSL_CTX *ctx, const char *str) {
    (void)ctx;
    (void)str;
    return 1;
}

int cps_boringssl_set_tlsext_host_name(SSL *ssl, const char *name) {
    if (ssl == NULL || name == NULL) {
        return 0;
    }
    return SSL_set_tlsext_host_name(ssl, name);
}

X509 *cps_boringssl_get_peer_certificate(SSL *ssl) {
    if (ssl == NULL) {
        return NULL;
    }
    return SSL_get_peer_certificate(ssl);
}

int cps_boringssl_chacha20poly1305_seal(const uint8_t *key, size_t key_len,
                                        const uint8_t *nonce, size_t nonce_len,
                                        const uint8_t *aad, size_t aad_len,
                                        const uint8_t *plaintext, size_t plaintext_len,
                                        uint8_t *out, size_t *out_len,
                                        size_t max_out_len) {
    if (key == NULL || nonce == NULL || out == NULL || out_len == NULL) {
        return 0;
    }
    if (key_len != 32 || nonce_len != 12) {
        return 0;
    }

    EVP_AEAD_CTX ctx;
    EVP_AEAD_CTX_zero(&ctx);

    int ok = 0;
    if (!EVP_AEAD_CTX_init(&ctx, EVP_aead_chacha20_poly1305(), key, key_len,
                           EVP_AEAD_DEFAULT_TAG_LENGTH, NULL)) {
        EVP_AEAD_CTX_cleanup(&ctx);
        return 0;
    }

    ok = EVP_AEAD_CTX_seal(
        &ctx,
        out,
        out_len,
        max_out_len,
        nonce,
        nonce_len,
        plaintext,
        plaintext_len,
        aad,
        aad_len
    );
    EVP_AEAD_CTX_cleanup(&ctx);
    return ok;
}

int cps_boringssl_chacha20poly1305_open(const uint8_t *key, size_t key_len,
                                        const uint8_t *nonce, size_t nonce_len,
                                        const uint8_t *aad, size_t aad_len,
                                        const uint8_t *ciphertext, size_t ciphertext_len,
                                        uint8_t *out, size_t *out_len,
                                        size_t max_out_len) {
    if (key == NULL || nonce == NULL || out == NULL || out_len == NULL) {
        return 0;
    }
    if (key_len != 32 || nonce_len != 12) {
        return 0;
    }

    EVP_AEAD_CTX ctx;
    EVP_AEAD_CTX_zero(&ctx);

    int ok = 0;
    if (!EVP_AEAD_CTX_init(&ctx, EVP_aead_chacha20_poly1305(), key, key_len,
                           EVP_AEAD_DEFAULT_TAG_LENGTH, NULL)) {
        EVP_AEAD_CTX_cleanup(&ctx);
        return 0;
    }

    ok = EVP_AEAD_CTX_open(
        &ctx,
        out,
        out_len,
        max_out_len,
        nonce,
        nonce_len,
        ciphertext,
        ciphertext_len,
        aad,
        aad_len
    );
    EVP_AEAD_CTX_cleanup(&ctx);
    return ok;
}

int cps_boringssl_chacha20_hp_mask(const uint8_t *key, size_t key_len,
                                   const uint8_t *sample, size_t sample_len,
                                   uint8_t *out_mask, size_t out_mask_len) {
    static const uint8_t zeros[5] = {0, 0, 0, 0, 0};
    uint8_t nonce[12];
    uint32_t counter;

    if (key == NULL || sample == NULL || out_mask == NULL) {
        return 0;
    }
    if (key_len != 32 || sample_len < 16 || out_mask_len < 5 || out_mask_len > 5) {
        return 0;
    }

    counter = ((uint32_t)sample[0]) |
              ((uint32_t)sample[1] << 8) |
              ((uint32_t)sample[2] << 16) |
              ((uint32_t)sample[3] << 24);
    memcpy(nonce, sample + 4, sizeof(nonce));
    CRYPTO_chacha_20(out_mask, zeros, out_mask_len, key, nonce, counter);
    return 1;
}
