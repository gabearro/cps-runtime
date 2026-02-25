# Standalone wasm config for CPS UI builds (clang + lld, no Emscripten runtime).

switch("os", "standalone")
switch("cpu", "wasm32")
switch("threads", "off")
switch("app", "console")
switch("cc", "clang")
switch("mm", "arc")
switch("noMain", "on")
switch("exceptions", "goto")
switch("stackTrace", "off")
switch("define", "wasm")
switch("define", "noSignalHandler")
switch("define", "useMalloc")
switch("define", "nimPreviewFloatRoundtrip")
switch("opt", "size")

let target = "wasm32-unknown-unknown-wasm"
switch("passC", "--target=" & target)
switch("passL", "--target=" & target)
switch("passL", "-fuse-ld=lld")
switch("passL", "-nostdlib")
switch("clang.options.linker", "")
switch("clang.cpp.options.linker", "")

var wasiSysroot = getEnv("WASI_SYSROOT")
if wasiSysroot.len == 0:
  if exists("/opt/homebrew/opt/wasi-libc/share/wasi-sysroot"):
    wasiSysroot = "/opt/homebrew/opt/wasi-libc/share/wasi-sysroot"
  elif exists("/usr/local/opt/wasi-libc/share/wasi-sysroot"):
    wasiSysroot = "/usr/local/opt/wasi-libc/share/wasi-sysroot"
  elif exists("/usr/share/wasi-sysroot"):
    wasiSysroot = "/usr/share/wasi-sysroot"

if wasiSysroot.len > 0:
  switch("passC", "-isystem " & wasiSysroot & "/include/wasm32-wasi")
  switch("passC", "-isystem " & wasiSysroot & "/include")

switch("passC", "-fvisibility=hidden")
switch("passC", "-fdata-sections")
switch("passC", "-ffunction-sections")

switch("passL", "-Wl,--no-entry")
switch("passL", "-Wl,--allow-undefined")
switch("passL", "-Wl,--gc-sections")
switch("passL", "-Wl,--strip-all")
switch("passL", "-Wl,--export-memory")

# Export runtime entrypoints expected by host.js / loader.js.
switch("passL", "-Wl,--export=nimui_start")
switch("passL", "-Wl,--export=nimui_hydrate")
switch("passL", "-Wl,--export=nimui_flush")
switch("passL", "-Wl,--export=nimui_unmount")
switch("passL", "-Wl,--export=nimui_dispatch_event")
switch("passL", "-Wl,--export=nimui_alloc")
switch("passL", "-Wl,--export=nimui_dealloc")
switch("passL", "-Wl,--export=nimui_last_error_len")
switch("passL", "-Wl,--export=nimui_copy_last_error")
switch("passL", "-Wl,--export=nimui_last_runtime_event_len")
switch("passL", "-Wl,--export=nimui_copy_last_runtime_event")
switch("passL", "-Wl,--export=nimui_last_hydration_error_len")
switch("passL", "-Wl,--export=nimui_copy_last_hydration_error")
switch("passL", "-Wl,--export=nimui_set_last_hydration_error")
switch("passL", "-Wl,--export=nimui_route_changed")
switch("passL", "-Wl,--export=nimui_net_fetch_resolve")
switch("passL", "-Wl,--export=nimui_net_fetch_reject")
switch("passL", "-Wl,--export=nimui_net_ws_open")
switch("passL", "-Wl,--export=nimui_net_ws_message")
switch("passL", "-Wl,--export=nimui_net_ws_error")
switch("passL", "-Wl,--export=nimui_net_ws_closed")
switch("passL", "-Wl,--export=nimui_net_sse_open")
switch("passL", "-Wl,--export=nimui_net_sse_message")
switch("passL", "-Wl,--export=nimui_net_sse_error")
switch("passL", "-Wl,--export=nimui_net_sse_closed")
switch("passL", "-Wl,--export=__heap_base")
