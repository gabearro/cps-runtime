#!/bin/bash
set -e

echo "--- CPS HTTP ---"
benchmarks/bench_http_cps_server &
PID=$!
sleep 2
hey -cpus 10 -c 32 -z 10s http://127.0.0.1:8080/ 2>&1 | grep "Requests/sec"
kill $PID 2>/dev/null
wait $PID 2>/dev/null || true
sleep 2

echo "--- asyncdispatch ---"
benchmarks/bench_http_asyncdispatch_server &
PID=$!
sleep 2
hey -cpus 10 -c 32 -z 10s http://127.0.0.1:8080/ 2>&1 | grep "Requests/sec"
kill $PID 2>/dev/null
wait $PID 2>/dev/null || true
sleep 2

echo "--- raw CPS ---"
benchmarks/bench_http_raw_cps_server &
PID=$!
sleep 2
hey -cpus 10 -c 32 -z 10s http://127.0.0.1:8080/ 2>&1 | grep "Requests/sec"
kill $PID 2>/dev/null
wait $PID 2>/dev/null || true
