#!/usr/bin/env bash
set -euo pipefail

WASM_PATH="${1:-}"
if [[ -z "$WASM_PATH" || ! -f "$WASM_PATH" ]]; then
  echo "usage: $0 <path-to-wasm>" >&2
  exit 1
fi

node - "$WASM_PATH" <<'NODE'
const fs = require("node:fs");

const wasmPath = process.argv[2];
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(mod);

const blocked = [];
const allowedModules = new Set(["env", "nimui"]);
const allowedNames = new Set(["malloc", "realloc", "free", "calloc", "memcmp", "memchr", "strtod"]);

for (const imp of imports) {
  const full = `${imp.module}.${imp.name}`;
  if (!allowedModules.has(imp.module)) {
    blocked.push(`${full} (unexpected module)`);
    continue;
  }
  if (!imp.name.startsWith("nimui_") && !allowedNames.has(imp.name)) {
    blocked.push(`${full} (unexpected import symbol)`);
    continue;
  }
  if (/emscripten/i.test(imp.name) || /^__emscripten/i.test(imp.name) || /^___syscall/i.test(imp.name)) {
    blocked.push(`${full} (emscripten runtime symbol)`);
  }
}

if (blocked.length > 0) {
  console.error("Blocked wasm imports detected:");
  for (const b of blocked) {
    console.error(`  - ${b}`);
  }
  process.exit(1);
}

console.log("WASM imports look clean:");
for (const imp of imports) {
  console.log(`  - ${imp.module}.${imp.name} (${imp.kind})`);
}
NODE
