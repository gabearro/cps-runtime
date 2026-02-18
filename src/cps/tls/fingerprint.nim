## TLS and HTTP/2 Fingerprint Profiles
##
## Pure data types describing browser TLS ClientHello and HTTP/2 fingerprints.
## Used by tls.nim, http2.nim, and client.nim to impersonate real browsers.
## No SSL dependency — this is just configuration data.

type
  TlsFingerprint* = ref object
    minVersion*, maxVersion*: uint16       ## TLS version range (e.g. 0x0301=1.0, 0x0303=1.2, 0x0304=1.3)
    cipherList*: string                    ## TLS 1.2 ciphers (colon-separated OpenSSL format)
    cipherSuites*: string                  ## TLS 1.3 suites (colon-separated)
    supportedGroups*: string               ## e.g. "X25519:P-256:P-384"
    signatureAlgorithms*: string           ## e.g. "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:..."
    alpnProtocols*: seq[string]            ## @["h2", "http/1.1"]
    greaseEnabled*: bool                   ## BoringSSL GREASE (random unknown values)
    permuteExtensions*: bool               ## BoringSSL extension randomization
    certCompression*: bool                 ## Advertise Brotli cert compression
    alpsEnabled*: bool                     ## ALPS extension (Application-Layer Protocol Settings)
    userAgent*: string                     ## Matching User-Agent header

  Http2Fingerprint* = ref object
    settings*: seq[(uint16, uint32)]       ## SETTINGS frame params (id, value) in order
    windowUpdateIncrement*: uint32         ## Connection WINDOW_UPDATE (0 = skip)
    pseudoHeaderOrder*: seq[string]        ## e.g. @[":method", ":authority", ":scheme", ":path"]

  BrowserProfile* = ref object
    name*: string
    tls*: TlsFingerprint
    h2*: Http2Fingerprint

# ============================================================
# Chrome ~131 profile
# ============================================================

proc chromeProfile*(): BrowserProfile =
  ## Chrome ~131 TLS + HTTP/2 fingerprint.
  ## GREASE, extension permutation, cert compression, ALPS enabled.
  let tls = TlsFingerprint(
    minVersion: 0x0303,  # TLS 1.2
    maxVersion: 0x0304,  # TLS 1.3
    cipherList: "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:" &
                "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" &
                "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" &
                "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:" &
                "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:" &
                "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA",
    cipherSuites: "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
    supportedGroups: "X25519Kyber768Draft00:X25519:P-256:P-384",
    signatureAlgorithms: "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:rsa_pkcs1_sha256:" &
                         "ecdsa_secp384r1_sha384:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:" &
                         "rsa_pss_rsae_sha512:rsa_pkcs1_sha512",
    alpnProtocols: @["h2", "http/1.1"],
    greaseEnabled: true,
    permuteExtensions: true,
    certCompression: true,
    alpsEnabled: true,
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  )
  let h2 = Http2Fingerprint(
    settings: @[
      (0x1'u16, 65536'u32),    # HEADER_TABLE_SIZE
      (0x2'u16, 0'u32),        # ENABLE_PUSH (disabled)
      (0x3'u16, 1000'u32),     # MAX_CONCURRENT_STREAMS
      (0x4'u16, 6291456'u32),  # INITIAL_WINDOW_SIZE (6MB)
      (0x5'u16, 16384'u32),    # MAX_FRAME_SIZE
      (0x8'u16, 1'u32),        # ENABLE_CONNECT_PROTOCOL
    ],
    windowUpdateIncrement: 15663105,  # Chrome's connection window update
    pseudoHeaderOrder: @[":method", ":authority", ":scheme", ":path"]
  )
  BrowserProfile(name: "Chrome/131", tls: tls, h2: h2)

# ============================================================
# Firefox ~133 profile
# ============================================================

proc firefoxProfile*(): BrowserProfile =
  ## Firefox ~133 TLS + HTTP/2 fingerprint.
  ## No GREASE, no extension permutation. Different H2 SETTINGS + pseudo-header order.
  let tls = TlsFingerprint(
    minVersion: 0x0303,  # TLS 1.2
    maxVersion: 0x0304,  # TLS 1.3
    cipherList: "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384:" &
                "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" &
                "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:" &
                "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" &
                "ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:" &
                "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:" &
                "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA",
    cipherSuites: "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
    supportedGroups: "X25519:P-256:P-384:P-521:ffdhe2048:ffdhe3072",
    signatureAlgorithms: "ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:ecdsa_secp521r1_sha512:" &
                         "rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:" &
                         "rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512:" &
                         "ecdsa_sha1:rsa_pkcs1_sha1",
    alpnProtocols: @["h2", "http/1.1"],
    greaseEnabled: false,
    permuteExtensions: false,
    certCompression: false,
    alpsEnabled: false,
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:133.0) Gecko/20100101 Firefox/133.0"
  )
  let h2 = Http2Fingerprint(
    settings: @[
      (0x1'u16, 65536'u32),    # HEADER_TABLE_SIZE
      (0x3'u16, 100'u32),      # MAX_CONCURRENT_STREAMS
      (0x4'u16, 131072'u32),   # INITIAL_WINDOW_SIZE (128KB)
      (0x5'u16, 16384'u32),    # MAX_FRAME_SIZE
    ],
    windowUpdateIncrement: 12517377,  # Firefox's connection window update
    pseudoHeaderOrder: @[":method", ":path", ":authority", ":scheme"]
  )
  BrowserProfile(name: "Firefox/133", tls: tls, h2: h2)
