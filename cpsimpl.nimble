# Package
version       = "1.0.0"
author        = "Gabriel"
description   = "Continuation-Passing Style runtime for async Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "zippy >= 0.10.0"

import strutils

task test, "Run tests":
  exec "nim c -r tests/core/test_cps_core.nim"
  exec "nim c -r tests/core/test_cps_macro.nim"
  exec "nim c -r tests/core/test_cps_hardening_contracts.nim"
  exec "nim c -r tests/core/test_try_finally.nim"
  exec "bash tests/core/test_try_finally_compile_fail.sh"
  exec "nim c -r tests/core/test_event_loop.nim"
  exec "nim c -r tests/core/test_event_loop_timers.nim"
  exec "nim c -r tests/concurrency/test_sync_cancellation.nim"
  exec "nim c -r tests/concurrency/test_channels_cancellation.nim"
  exec "nim c -r tests/concurrency/test_taskgroup_multiwaiter.nim"
  exec "nim c -r tests/http/test_https_client.nim"
  exec "nim c -r tests/http/test_compression.nim"
  exec "nim c -r tests/http/test_http_compression.nim"
  exec "nim c -r tests/http/test_ws_compression.nim"
  exec "nim c -r tests/http/test_ws_hardening.nim"
  exec "nim c -r tests/http/test_sse_compression.nim"
  exec "nim c -r tests/quic/test_quic_primitives.nim"

task test_quic_primitives, "Run QUIC primitive unit tests":
  exec "nim c -r tests/quic/test_quic_primitives.nim"

task test_quic_core, "Run QUIC core unit tests":
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_primitives.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_protected_packet_pipeline.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_varint_and_packet_codec.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_frame_codec_full.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_transport_params.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_fault_injection.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_recovery_loss_pto.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_retry_restart.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_flow_control.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_retransmit_probe_scheduler.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_cid_rotation_and_retire.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_path_migration.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_path_rebinding_migration.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_endpoint_lifecycle_cleanup.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_server_unknown_short_packet.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_0rtt_and_key_update.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_0rtt_real_handshake_paths.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_key_update_real_traffic.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_duplicate_packet_suppression.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_tls_handshake_crypto_levels.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_cipher_negotiation_and_hp.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_datagram.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_stateless_reset.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_quic_v2_codec_and_negotiation.nim"

task test_quic_python_interop, "Run QUIC Python venv interop tests":
  exec "nim c -r -d:useBoringSSL tests/quic/test_python_quic_interop.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_python_quic_live_interop.nim"

task test_http3_core, "Run HTTP/3 + QPACK core tests":
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_frame_codec.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_static_dynamic.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_huffman.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_blocked_streams.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_instruction_stream_fragmentation.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_instruction_stream_errors.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_qpack_required_insert_count_concurrency.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_settings_and_control_streams.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_control_stream_legality_matrix.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_goaway.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_header_validation.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_request_state_machine_strict.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_server_body_limits.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_qpack_encoder_stream_flush.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_server_qpack_unblock.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_client_qpack_blocked_decode.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_client_header_validation.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_client_timeout.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_push_lifecycle.nim"

task test_http3_python_interop, "Run HTTP/3 Python venv interop tests":
  exec "nim c -r -d:useBoringSSL tests/quic/test_python_http3_interop.nim"
  exec "nim c -r -d:useBoringSSL tests/quic/test_python_http3_live_interop.nim"

task test_webtransport_core, "Run WebTransport core tests":
  exec "nim c -r -d:useBoringSSL tests/http/test_webtransport_session.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_webtransport_streams_and_datagrams.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_webtransport_error_propagation.nim"

task test_masque_core, "Run MASQUE core tests":
  exec "nim c -r -d:useBoringSSL tests/http/test_masque_connect_udp.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_masque_connect_ip.nim"
  exec "nim c -r -d:useBoringSSL tests/http/test_masque_capsule_protocol.nim"

task test_quic_full, "Run full QUIC (v1+v2) suite":
  exec "nimble test_quic_core"

task test_http3_full, "Run full HTTP/3 suite":
  exec "nimble test_http3_core"

task test_quic_http3_python_interop_full, "Run expanded QUIC+HTTP3 Python interop":
  exec "nimble test_quic_python_interop"
  exec "nimble test_http3_python_interop"

task test_http3_browser_interop, "Run HTTP/3 browser interop checks":
  exec """bash -lc 'if [ -n "${CPS_HTTP3_INTEROP_URL:-}" ]; then CPS_HTTP3_REQUIRE_TARGET="${CPS_HTTP3_REQUIRE_TARGET:-1}" bash tests/http/browser/run_playwright_http3.sh; else nim c -r -d:useBoringSSL tests/http/test_http3_browser_live_interop.nim; fi'"""

task test_http3_browser_live_local, "Run live browser->local CPS HTTP/3 interop checks":
  exec "nim c -r -d:useBoringSSL tests/http/test_http3_browser_live_interop.nim"

task gui, "GUI DSL toolchain (check/generate/build/run/dev/coverage/parity/emit/run-nim)":
  var args = commandLineParams
  var filtered: seq[string] = @[]
  for arg in args:
    if arg == "gui" or arg == "--":
      continue
    if arg.startsWith("--hints:") or arg.startsWith("--verbosity:") or
       arg.startsWith("--define:") or arg.startsWith("--colors:"):
      continue
    filtered.add arg

  var cmd = "nim c -r --path:src src/cps/gui/cli.nim"
  if filtered.len > 0:
    for arg in filtered:
      cmd &= " " & arg
  exec cmd
