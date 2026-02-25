#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

run_expect_fail() {
  local file="$1"
  local output
  if output=$(nim c "$file" 2>&1); then
    echo "FAIL: expected compile failure for $file"
    echo "$output"
    exit 1
  fi
  if [[ "$output" != *"Unsupported CPS try/finally"* ]]; then
    echo "FAIL: unexpected compile error for $file"
    echo "$output"
    exit 1
  fi
  echo "PASS: compile-fail diagnostic for $file"
}

run_expect_fail tests/core/compilefail/try_finally_return.nim
run_expect_fail tests/core/compilefail/try_finally_break.nim
run_expect_fail tests/core/compilefail/try_finally_continue.nim

echo "All try/finally compile-fail tests passed!"
