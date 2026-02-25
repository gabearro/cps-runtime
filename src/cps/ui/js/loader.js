import { createHostRuntime } from "./host.js";

async function loadWasmBytes(source) {
  if (source instanceof ArrayBuffer) {
    return source;
  }
  if (ArrayBuffer.isView(source)) {
    return source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
  }
  if (typeof source !== "string") {
    throw new Error("loadNimUiWasm source must be a path/URL or binary buffer");
  }

  const isNode = typeof process !== "undefined" && !!process.versions?.node;
  if (isNode) {
    const { readFile } = await import("node:fs/promises");
    const data = await readFile(source);
    return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
  }

  const response = await fetch(source);
  if (!response.ok) {
    throw new Error(`failed to fetch wasm: ${response.status} ${response.statusText}`);
  }
  return await response.arrayBuffer();
}

export async function loadNimUiWasm(wasmSource, opts = {}) {
  const selector = opts.selector ?? "#app";
  const mode = opts.mode ?? "mount";
  const documentRef = opts.documentRef ?? globalThis.document;
  const onRuntimeError = opts.onRuntimeError;
  const onRuntimeEvent = opts.onRuntimeEvent;
  const autoUnmountOnFatal = opts.autoUnmountOnFatal ?? true;

  const host = createHostRuntime(documentRef, {
    onRuntimeError,
    onRuntimeEvent,
    autoUnmountOnFatal
  });
  const bytes = await loadWasmBytes(wasmSource);
  const { instance, module } = await WebAssembly.instantiate(bytes, {
    env: host.imports,
    nimui: host.imports
  });
  host.bindInstance(instance);
  if (mode === "hydrate") {
    host.hydrate(selector);
  } else {
    host.start(selector);
  }

  return { instance, module, host };
}
