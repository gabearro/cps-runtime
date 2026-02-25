#!/bin/bash
# HTTP Server Benchmark: CPS HTTP stack vs Raw CPS vs std/asynchttpserver
# Uses wrk for load testing
set -e

WRK_THREADS=2
WRK_CONNECTIONS=100
WRK_DURATION=10s
PORT=8080
HOST="http://127.0.0.1:$PORT"

DIR="$(cd "$(dirname "$0")" && pwd)"

run_bench() {
  local name="$1"
  local bin="$2"

  echo ""
  echo "============================================"
  echo "  $name"
  echo "============================================"

  # Start server
  "$bin" &
  local pid=$!
  sleep 1

  # Verify it's running
  if ! curl -s "$HOST/" > /dev/null 2>&1; then
    echo "ERROR: Server failed to start"
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null || true
    return 1
  fi

  # Quick warmup
  wrk -t1 -c10 -d2s "$HOST/" > /dev/null 2>&1

  # Benchmark
  echo "--- wrk -t$WRK_THREADS -c$WRK_CONNECTIONS -d$WRK_DURATION ---"
  wrk -t$WRK_THREADS -c$WRK_CONNECTIONS -d$WRK_DURATION "$HOST/"

  # Stop server
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null || true
  sleep 1
}

echo "HTTP Server Benchmark"
echo "wrk: ${WRK_THREADS} threads, ${WRK_CONNECTIONS} connections, ${WRK_DURATION} duration"
echo "All servers: single-threaded, -d:danger, response = 'Hello, World!'"

run_bench "std/asynchttpserver (stdlib)" "$DIR/bench_http_asyncdispatch_server"
run_bench "Raw CPS TCP (cps-impl, no HTTP parsing)" "$DIR/bench_http_raw_cps_server"
run_bench "CPS HTTP Server (cps-impl, full stack)" "$DIR/bench_http_cps_server"

echo ""
echo "============================================"
echo "  Done"
echo "============================================"
