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
