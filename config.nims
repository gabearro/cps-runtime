# SSL/TLS library configuration (conditional BoringSSL vs OpenSSL).
# Base settings (path, threads, mm, deepcopy) remain in nim.cfg.
#
# Use -d:useBoringSSL to link against BoringSSL (deps/boringssl/)
# instead of Homebrew OpenSSL 3.x.

switch("define", "sslVersion:3")
switch("dynlibOverride", "libssl.3.dylib")
switch("dynlibOverride", "libcrypto.3.dylib")

if defined(useBoringSSL):
  switch("passL", "-Ldeps/boringssl/lib")
  switch("passL", "-lssl")
  switch("passL", "-lcrypto")
  switch("passC", "-Ideps/boringssl/include")
  switch("passL", "-lc++")  # BoringSSL internals need C++ stdlib
else:
  switch("passL", "-L/opt/homebrew/opt/openssl@3/lib")
  switch("passL", "-lssl")
  switch("passL", "-lcrypto")
  switch("passL", "-Wl,-rpath,/opt/homebrew/opt/openssl@3/lib")
