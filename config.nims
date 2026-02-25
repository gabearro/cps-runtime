# UI standalone wasm profile.
if defined(uiWasm):
  include "config.ui.wasm.nims"

# SSL/TLS library configuration (conditional BoringSSL vs OpenSSL).
# Base settings (path, threads, mm, deepcopy) remain in nim.cfg.
#
# Use -d:useBoringSSL to link against BoringSSL (deps/boringssl/)
# instead of Homebrew OpenSSL 3.x.

if not defined(uiWasm):
  switch("define", "sslVersion:3")

  if defined(useBoringSSL):
    switch("dynlibOverride", "ssl")
    switch("dynlibOverride", "crypto")
    switch("passL", "-Ldeps/boringssl/lib")
    switch("passL", "-lssl")
    switch("passL", "-lcrypto")
    switch("passC", "-Ideps/boringssl/include")
    switch("passL", "-lc++")  # BoringSSL internals need C++ stdlib
  elif defined(macosx):
    switch("dynlibOverride", "libssl.3.dylib")
    switch("dynlibOverride", "libcrypto.3.dylib")
    switch("passL", "-L/opt/homebrew/opt/openssl@3/lib")
    switch("passL", "-lssl")
    switch("passL", "-lcrypto")
    switch("passL", "-Wl,-rpath,/opt/homebrew/opt/openssl@3/lib")
  elif defined(linux):
    switch("dynlibOverride", "libssl.so")
    switch("dynlibOverride", "libcrypto.so")
    switch("passL", "-lssl")
    switch("passL", "-lcrypto")
  elif defined(windows):
    # Use runtime dlopen (Nim's default) — user must have OpenSSL DLLs in PATH
    discard
