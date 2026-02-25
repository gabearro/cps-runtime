import { EVENT_NAMES } from "./event_names.generated.js";

const BOOLEAN_PROPS = new Set(["checked", "selected", "disabled"]);

function queueFlush(fn) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(fn);
    return;
  }
  Promise.resolve().then(fn);
}

function normalizeBool(value) {
  const v = String(value ?? "").toLowerCase();
  return !(v === "" || v === "0" || v === "false" || v === "off" || v === "no");
}

function decodeOptionsMask(mask) {
  const bits = Number(mask) | 0;
  return {
    capture: (bits & 1) !== 0,
    passive: (bits & 2) !== 0,
    once: (bits & 4) !== 0
  };
}

function pushEventExtra(pairs, key, value) {
  if (value === null || typeof value === "undefined") {
    return;
  }
  const kind = typeof value;
  if (kind === "number") {
    if (!Number.isFinite(value)) {
      return;
    }
    pairs.push([key, String(value)]);
    return;
  }
  if (kind === "boolean") {
    pairs.push([key, value ? "true" : "false"]);
    return;
  }
  if (kind === "string") {
    pairs.push([key, value]);
  }
}

function collectEventExtras(ev, currentTarget = null, eventName = "") {
  const extras = [];
  if (!ev || typeof ev !== "object") {
    return extras;
  }

  const keys = [
    "code",
    "repeat",
    "location",
    "isComposing",
    "deltaX",
    "deltaY",
    "deltaZ",
    "deltaMode",
    "detail",
    "buttons",
    "pointerId",
    "pointerType",
    "pressure",
    "tiltX",
    "tiltY",
    "twist",
    "width",
    "height",
    "isPrimary",
    "movementX",
    "movementY",
    "offsetX",
    "offsetY",
    "pageX",
    "pageY",
    "screenX",
    "screenY",
    "relatedTarget",
    "inputType",
    "data",
    "clipboardData",
    "timeStamp"
  ];

  for (const key of keys) {
    if (key === "relatedTarget") {
      const related = ev.relatedTarget;
      pushEventExtra(extras, "relatedTargetTag", related?.tagName?.toLowerCase?.());
      continue;
    }

    if (key === "clipboardData") {
      const clipboard = ev.clipboardData;
      const text = clipboard?.getData?.("text") ?? "";
      if (text) {
        pushEventExtra(extras, "clipboardText", text);
      }
      continue;
    }

    pushEventExtra(extras, key, ev[key]);
  }

  if (Array.isArray(ev.touches)) {
    pushEventExtra(extras, "touches", ev.touches.length);
  }
  if (Array.isArray(ev.changedTouches)) {
    pushEventExtra(extras, "changedTouches", ev.changedTouches.length);
  }

  if (currentTarget && typeof currentTarget.getAttribute === "function") {
    pushEventExtra(extras, "currentTargetTarget", currentTarget.getAttribute("target") ?? "");
    pushEventExtra(extras, "currentTargetDownload", currentTarget.getAttribute("download") ?? "");
    pushEventExtra(extras, "currentTargetRel", currentTarget.getAttribute("rel") ?? "");
  }

  if (eventName === "submit" && currentTarget) {
    try {
      const FormDataCtor = globalThis.FormData;
      const UrlSearchCtor = globalThis.URLSearchParams;
      if (typeof FormDataCtor === "function" && typeof UrlSearchCtor === "function") {
        const formData = new FormDataCtor(currentTarget);
        const encoded = new UrlSearchCtor(formData).toString();
        if (encoded.length > 0) {
          pushEventExtra(extras, "formPayload", encoded);
        }
      }
    } catch (_) {
      // ignore form payload extraction failures
    }
  }

  return extras;
}

export function createHostRuntime(doc = globalThis.document, opts = {}) {
  if (!doc) {
    throw new Error("createHostRuntime requires a document-like object");
  }

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  let instance = null;
  let memory = null;
  let flushQueued = false;
  let historySubscribed = false;
  let fatalError = null;
  let pendingPanicError = "";

  const onRuntimeError = typeof opts.onRuntimeError === "function" ? opts.onRuntimeError : null;
  const onRuntimeEvent = typeof opts.onRuntimeEvent === "function" ? opts.onRuntimeEvent : null;
  const autoUnmountOnFatal = opts.autoUnmountOnFatal !== false;

  const nodes = new Map();
  const nodeToId = new WeakMap();
  const listeners = new Map();
  const fetchControllers = new Map();
  const wsSockets = new Map();
  const sseStreams = new Map();
  const mallocSizes = new Map();
  const freeBlocks = [];
  let heapTop = 0;
  let hydrationActive = false;
  let hydrationRootId = 0;
  const hydrationCursorByParent = new Map();

  function registerNode(nodeId, node) {
    nodes.set(nodeId, node);
    if (node && typeof node === "object") {
      nodeToId.set(node, nodeId);
    }
  }

  function forgetNode(nodeId, node) {
    nodes.delete(nodeId);
    if (node && typeof node === "object") {
      nodeToId.delete(node);
    }
  }

  function closeManagedNetworkObjects() {
    for (const controller of fetchControllers.values()) {
      try {
        controller.abort();
      } catch (_) {
        // ignore abort failures during runtime reset
      }
    }
    fetchControllers.clear();

    for (const ws of wsSockets.values()) {
      try {
        ws.close(1000, "runtime-reset");
      } catch (_) {
        // ignore close failures during runtime reset
      }
    }
    wsSockets.clear();

    for (const stream of sseStreams.values()) {
      try {
        stream.close();
      } catch (_) {
        // ignore close failures during runtime reset
      }
    }
    sseStreams.clear();
  }

  function bindInstance(wasmInstance) {
    closeManagedNetworkObjects();
    instance = wasmInstance;
    memory = wasmInstance.exports.memory;
    nodes.clear();
    listeners.clear();
    mallocSizes.clear();
    freeBlocks.length = 0;
    heapTop = 0;
    historySubscribed = false;
    fatalError = null;
    pendingPanicError = "";
    hydrationActive = false;
    hydrationRootId = 0;
    hydrationCursorByParent.clear();
    setNimHydrationError("");
  }

  function memoryView() {
    if (!memory) {
      throw new Error("WASM memory unavailable (bindInstance not called)");
    }
    return new Uint8Array(memory.buffer);
  }

  function align8(value) {
    return (value + 7) & ~7;
  }

  function insertFreeBlock(ptr, size) {
    let start = Number(ptr) >>> 0;
    let span = align8(Number(size) >>> 0);
    if (!start || span === 0) {
      return;
    }

    let idx = 0;
    while (idx < freeBlocks.length && freeBlocks[idx].ptr < start) {
      idx += 1;
    }

    const prev = idx > 0 ? freeBlocks[idx - 1] : null;
    if (prev && prev.ptr + prev.size === start) {
      prev.size += span;
      start = prev.ptr;
      span = prev.size;
      idx -= 1;
    } else {
      freeBlocks.splice(idx, 0, { ptr: start, size: span });
    }

    const current = freeBlocks[idx];
    while (idx + 1 < freeBlocks.length) {
      const next = freeBlocks[idx + 1];
      if (current.ptr + current.size !== next.ptr) {
        break;
      }
      current.size += next.size;
      freeBlocks.splice(idx + 1, 1);
    }
  }

  function takeFreeBlock(size) {
    const needed = align8(Number(size) >>> 0);
    if (needed === 0) {
      return 0;
    }
    for (let i = 0; i < freeBlocks.length; i += 1) {
      const block = freeBlocks[i];
      if (block.size < needed) {
        continue;
      }
      const ptr = block.ptr;
      if (block.size === needed) {
        freeBlocks.splice(i, 1);
      } else {
        block.ptr += needed;
        block.size -= needed;
      }
      return ptr;
    }
    return 0;
  }

  function ensureHeapTop() {
    if (heapTop > 0) {
      return;
    }
    const heapBase = instance?.exports?.__heap_base;
    if (typeof heapBase === "number") {
      heapTop = heapBase;
      return;
    }
    if (heapBase && typeof heapBase.value === "number") {
      heapTop = heapBase.value;
      return;
    }
    heapTop = 64 * 1024;
  }

  function ensureMemoryCapacity(requiredBytes) {
    if (!memory) {
      throw new Error("WASM memory unavailable (bindInstance not called)");
    }
    const pageSize = 64 * 1024;
    const currentBytes = memory.buffer.byteLength;
    if (requiredBytes <= currentBytes) {
      return;
    }
    const missingPages = Math.ceil((requiredBytes - currentBytes) / pageSize);
    memory.grow(missingPages);
  }

  function mallocImpl(size) {
    const n = align8(Number(size) >>> 0);
    if (n === 0) {
      return 0;
    }
    ensureHeapTop();
    let ptr = takeFreeBlock(n);
    if (!ptr) {
      ptr = heapTop;
      heapTop = align8(heapTop + n);
    }
    ensureMemoryCapacity(heapTop + 8);
    mallocSizes.set(ptr, n);
    return ptr;
  }

  function freeImpl(ptr) {
    if (!ptr) {
      return;
    }
    const base = Number(ptr) >>> 0;
    const size = mallocSizes.get(base);
    if (!size) {
      return;
    }
    mallocSizes.delete(base);
    insertFreeBlock(base, size);
  }

  function callocImpl(count, size) {
    const n = (Number(count) >>> 0) * (Number(size) >>> 0);
    const ptr = mallocImpl(n);
    if (ptr && n > 0) {
      memoryView().fill(0, ptr, ptr + n);
    }
    return ptr;
  }

  function reallocImpl(ptr, size) {
    const oldPtr = Number(ptr) >>> 0;
    const n = Number(size) >>> 0;
    if (oldPtr === 0) {
      return mallocImpl(n);
    }
    if (n === 0) {
      freeImpl(oldPtr);
      return 0;
    }
    const nextPtr = mallocImpl(n);
    const oldSize = mallocSizes.get(oldPtr) ?? 0;
    const copyLen = Math.min(oldSize, n);
    if (copyLen > 0) {
      const view = memoryView();
      view.copyWithin(nextPtr, oldPtr, oldPtr + copyLen);
    }
    freeImpl(oldPtr);
    return nextPtr;
  }

  function memcmpImpl(aPtr, bPtr, len) {
    const a = Number(aPtr) >>> 0;
    const b = Number(bPtr) >>> 0;
    const n = Number(len) >>> 0;
    const view = memoryView();
    for (let i = 0; i < n; i += 1) {
      const diff = (view[a + i] | 0) - (view[b + i] | 0);
      if (diff !== 0) {
        return diff;
      }
    }
    return 0;
  }

  function memchrImpl(ptr, ch, len) {
    const base = Number(ptr) >>> 0;
    const needle = Number(ch) & 0xff;
    const n = Number(len) >>> 0;
    const view = memoryView();
    for (let i = 0; i < n; i += 1) {
      if (view[base + i] === needle) {
        return base + i;
      }
    }
    return 0;
  }

  function strtodImpl(nptr, endPtrPtr) {
    const start = Number(nptr) >>> 0;
    const endPtrOut = Number(endPtrPtr) >>> 0;
    const view = memoryView();
    const dataView = new DataView(view.buffer);

    if (start === 0 || start >= view.length) {
      if (endPtrOut) {
        dataView.setUint32(endPtrOut, 0, true);
      }
      return 0;
    }

    let end = start;
    while (end < view.length && view[end] !== 0) {
      end += 1;
    }
    const raw = decoder.decode(view.subarray(start, end));
    const leadingWs = raw.match(/^\s*/)?.[0].length ?? 0;
    const token = raw
      .slice(leadingWs)
      .match(/^[+-]?(?:nan|infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/i)?.[0] ?? "";

    if (token.length == 0) {
      if (endPtrOut) {
        dataView.setUint32(endPtrOut, start, true);
      }
      return 0;
    }

    const parsed = Number(token);
    const value = Number.isNaN(parsed)
      ? (token.toLowerCase().includes("nan") ? Number.NaN : 0)
      : parsed;

    if (endPtrOut) {
      const consumed = start + leadingWs + token.length;
      dataView.setUint32(endPtrOut, consumed >>> 0, true);
    }
    return value;
  }

  function readString(ptr, len) {
    if (!ptr || !len) {
      return "";
    }
    return decoder.decode(memoryView().subarray(ptr, ptr + len));
  }

  function writeStringToMemory(text, dst, cap) {
    if (!dst || !cap) {
      return 0;
    }
    const bytes = encoder.encode(text ?? "");
    const n = Math.min(bytes.length, Math.max(0, (Number(cap) >>> 0) - 1));
    const view = memoryView();
    if (n > 0) {
      view.set(bytes.subarray(0, n), Number(dst) >>> 0);
    }
    view[(Number(dst) >>> 0) + n] = 0;
    return n;
  }

  function allocString(value) {
    const bytes = encoder.encode(value ?? "");
    if (bytes.length === 0) {
      return {
        ptr: 0,
        len: 0,
        free() {}
      };
    }
    const ptr = instance.exports.nimui_alloc(bytes.length);
    memoryView().set(bytes, ptr);
    return {
      ptr,
      len: bytes.length,
      free() {
        instance.exports.nimui_dealloc(ptr);
      }
    };
  }

  function allocExtrasBlob(pairs) {
    if (!pairs || pairs.length === 0) {
      return {
        ptr: 0,
        len: 0,
        free() {}
      };
    }

    let total = 0;
    const encoded = [];
    for (const [k, v] of pairs) {
      const keyBytes = encoder.encode(String(k));
      const valBytes = encoder.encode(String(v));
      encoded.push(keyBytes, valBytes);
      total += keyBytes.length + 1 + valBytes.length + 1;
    }

    const ptr = instance.exports.nimui_alloc(total);
    const view = memoryView();
    let cursor = ptr;
    for (let i = 0; i < encoded.length; i += 2) {
      const keyBytes = encoded[i];
      const valBytes = encoded[i + 1];
      view.set(keyBytes, cursor);
      cursor += keyBytes.length;
      view[cursor] = 0;
      cursor += 1;
      view.set(valBytes, cursor);
      cursor += valBytes.length;
      view[cursor] = 0;
      cursor += 1;
    }

    return {
      ptr,
      len: total,
      free() {
        instance.exports.nimui_dealloc(ptr);
      }
    };
  }

  function parsePairsBlob(blob) {
    if (!blob) {
      return [];
    }
    const parts = String(blob).split("\0");
    const pairs = [];
    for (let i = 0; i + 1 < parts.length; i += 2) {
      const key = parts[i] ?? "";
      if (!key) {
        continue;
      }
      pairs.push([key, parts[i + 1] ?? ""]);
    }
    return pairs;
  }

  function encodePairsBlob(pairs) {
    if (!Array.isArray(pairs) || pairs.length === 0) {
      return "";
    }
    let out = "";
    for (const pair of pairs) {
      if (!Array.isArray(pair) || pair.length < 2) {
        continue;
      }
      const key = String(pair[0] ?? "");
      if (!key) {
        continue;
      }
      const value = String(pair[1] ?? "");
      out += key;
      out += "\0";
      out += value;
      out += "\0";
    }
    return out;
  }

  function bytesToBase64(bytes) {
    if (!bytes || bytes.length === 0) {
      return "";
    }
    if (typeof Buffer !== "undefined") {
      return Buffer.from(bytes).toString("base64");
    }
    let binary = "";
    for (let i = 0; i < bytes.length; i += 1) {
      binary += String.fromCharCode(bytes[i]);
    }
    if (typeof btoa === "function") {
      return btoa(binary);
    }
    throw new Error("base64 encoding is not available in this runtime");
  }

  function responseHeaderPairs(headers) {
    const pairs = [];
    if (!headers) {
      return pairs;
    }
    if (typeof headers.forEach === "function") {
      headers.forEach((value, key) => {
        pairs.push([String(key), String(value)]);
      });
      return pairs;
    }
    if (Array.isArray(headers)) {
      for (const entry of headers) {
        if (!Array.isArray(entry) || entry.length < 2) {
          continue;
        }
        pairs.push([String(entry[0]), String(entry[1])]);
      }
      return pairs;
    }
    if (typeof headers === "object") {
      for (const [key, value] of Object.entries(headers)) {
        pairs.push([String(key), String(value)]);
      }
    }
    return pairs;
  }

  function ensureNode(nodeId) {
    const node = nodes.get(nodeId);
    if (!node) {
      throw new Error(`DOM node id ${nodeId} not found`);
    }
    return node;
  }

  function listenerKey(nodeId, eventCode, capture) {
    return `${nodeId}:${eventCode}:${capture ? 1 : 0}`;
  }

  function nextHydrationCandidate(parentId) {
    const parent = ensureNode(parentId);
    let cursor = hydrationCursorByParent.has(parentId)
      ? hydrationCursorByParent.get(parentId)
      : parent.firstChild;

    while (cursor && nodeToId.has(cursor)) {
      cursor = cursor.nextSibling;
    }

    hydrationCursorByParent.set(parentId, cursor ? cursor.nextSibling : null);
    return cursor;
  }

  function removeUnmanagedSubtree(node) {
    if (!node) {
      return;
    }
    const children = Array.from(node.childNodes ?? []);
    for (const child of children) {
      if (!nodeToId.has(child)) {
        if (child.parentNode) {
          child.parentNode.removeChild(child);
        }
        continue;
      }
      removeUnmanagedSubtree(child);
    }
  }

  function removeAllListenersForNodeId(nodeId) {
    const prefix = `${nodeId}:`;
    for (const [key, entry] of listeners.entries()) {
      if (!key.startsWith(prefix)) {
        continue;
      }
      if (entry?.node && typeof entry.node.removeEventListener === "function") {
        entry.node.removeEventListener(entry.eventName, entry.handler, { capture: !!entry?.options?.capture });
      }
      listeners.delete(key);
    }
  }

  function cleanupManagedSubtree(node) {
    const children = Array.from(node?.childNodes ?? []);
    for (const child of children) {
      cleanupManagedSubtree(child);
    }

    const nodeId = nodeToId.get(node);
    if (nodeId === undefined) {
      return;
    }

    removeAllListenersForNodeId(nodeId);
    forgetNode(nodeId, node);
  }

  function readNimLastError() {
    const lenFn = instance?.exports?.nimui_last_error_len;
    const copyFn = instance?.exports?.nimui_copy_last_error;
    if (typeof lenFn !== "function" || typeof copyFn !== "function") {
      return "";
    }
    const len = Number(lenFn()) >>> 0;
    if (len === 0) {
      return "";
    }
    const ptr = instance.exports.nimui_alloc(len + 1);
    try {
      const n = Number(copyFn(ptr, len + 1)) >>> 0;
      if (n === 0) {
        return "";
      }
      return decoder.decode(memoryView().subarray(ptr, ptr + n));
    } finally {
      instance.exports.nimui_dealloc(ptr);
    }
  }

  function clearNimLastError() {
    const clearFn = instance?.exports?.nimui_clear_last_error;
    if (typeof clearFn !== "function") {
      return;
    }
    clearFn();
  }

  function readNimLastHydrationError() {
    const lenFn = instance?.exports?.nimui_last_hydration_error_len;
    const copyFn = instance?.exports?.nimui_copy_last_hydration_error;
    if (typeof lenFn !== "function" || typeof copyFn !== "function") {
      return "";
    }
    const len = Number(lenFn()) >>> 0;
    if (len === 0) {
      return "";
    }
    const ptr = instance.exports.nimui_alloc(len + 1);
    try {
      const n = Number(copyFn(ptr, len + 1)) >>> 0;
      if (n === 0) {
        return "";
      }
      return decoder.decode(memoryView().subarray(ptr, ptr + n));
    } finally {
      instance.exports.nimui_dealloc(ptr);
    }
  }

  function setNimHydrationError(message) {
    const fn = instance?.exports?.nimui_set_last_hydration_error;
    if (typeof fn !== "function") {
      return;
    }
    if (!message) {
      try {
        fn(0, 0);
      } catch (_) {
        // ignore hydration error reset failures
      }
      return;
    }
    const msgBuf = allocString(String(message));
    try {
      fn(msgBuf.ptr, msgBuf.len);
    } catch (_) {
      // ignore hydration error writes when runtime is unavailable
    } finally {
      msgBuf.free();
    }
  }

  function reportHydrationMismatch(message) {
    const text = String(message ?? "hydration mismatch");
    setNimHydrationError(text);
    if (onRuntimeEvent) {
      try {
        onRuntimeEvent(JSON.stringify({ type: "hydration-mismatch", message: text }));
      } catch (_) {
        // ignore observer callback failures
      }
    }
  }

  function readNimRuntimeEvent() {
    const lenFn = instance?.exports?.nimui_last_runtime_event_len;
    const copyFn = instance?.exports?.nimui_copy_last_runtime_event;
    if (typeof lenFn !== "function" || typeof copyFn !== "function") {
      return "";
    }
    const len = Number(lenFn()) >>> 0;
    if (len === 0) {
      return "";
    }
    const ptr = instance.exports.nimui_alloc(len + 1);
    try {
      const n = Number(copyFn(ptr, len + 1)) >>> 0;
      if (n === 0) {
        return "";
      }
      return decoder.decode(memoryView().subarray(ptr, ptr + n));
    } finally {
      instance.exports.nimui_dealloc(ptr);
    }
  }

  function emitRuntimeEventFromNim() {
    if (!onRuntimeEvent) {
      return;
    }
    const payload = readNimRuntimeEvent();
    if (!payload) {
      return;
    }
    try {
      onRuntimeEvent(payload);
    } catch (_) {
      // ignore observer callback failures
    }
  }

  function consumePendingPanicError() {
    const message = pendingPanicError;
    pendingPanicError = "";
    return message;
  }

  function setFatal(op, message, nimError = "", nimHydrationError = "") {
    fatalError = {
      op,
      message: String(message ?? ""),
      nimError: String(nimError ?? ""),
      nimHydrationError: String(nimHydrationError ?? "")
    };

    if (onRuntimeError) {
      try {
        onRuntimeError(fatalError);
      } catch (_) {
        // ignore secondary errors from reporter
      }
    }

    if (autoUnmountOnFatal && typeof instance?.exports?.nimui_unmount === "function") {
      try {
        instance.exports.nimui_unmount();
      } catch (_) {
        // ignore follow-up errors
      }
    }
    return null;
  }

  function safeInvoke(op, fn) {
    if (fatalError) {
      return null;
    }
    clearNimLastError();
    pendingPanicError = "";
    try {
      const result = fn();
      const panicError = consumePendingPanicError();
      const nimError = readNimLastError();
      if (!panicError && !nimError) {
        return result;
      }
      const nimHydrationError = readNimLastHydrationError();
      const effectiveError = panicError || nimError;
      return setFatal(op, effectiveError, nimError || panicError, nimHydrationError);
    } catch (err) {
      const panicError = consumePendingPanicError();
      const nimError = readNimLastError();
      const nimHydrationError = readNimLastHydrationError();
      return setFatal(
        op,
        panicError || err?.message || String(err),
        nimError || panicError,
        nimHydrationError
      );
    }
  }

  function addListener(nodeId, eventCode, optionsMask) {
    const node = ensureNode(nodeId);
    const eventName = EVENT_NAMES[eventCode] ?? "click";
    const options = decodeOptionsMask(optionsMask);
    const key = listenerKey(nodeId, eventCode, options.capture);
    if (listeners.has(key)) {
      return;
    }

    const handler = (ev) => {
      const target = ev?.target;
      const currentTarget = ev?.currentTarget ?? node;
      const targetId = nodeToId.get(target) ?? nodeId;
      const value = target?.value ?? "";
      const keyValue = ev?.key ?? "";
      const checked = target?.checked ? 1 : 0;

      const valueBuf = allocString(String(value));
      const keyBuf = allocString(String(keyValue));
      const extrasBuf = allocExtrasBlob(collectEventExtras(ev, currentTarget, eventName));
      try {
        const flags = safeInvoke("nimui_dispatch_event", () => instance.exports.nimui_dispatch_event(
          eventCode,
          targetId,
          nodeId,
          valueBuf.ptr,
          valueBuf.len,
          keyBuf.ptr,
          keyBuf.len,
          checked,
          ev?.ctrlKey ? 1 : 0,
          ev?.altKey ? 1 : 0,
          ev?.shiftKey ? 1 : 0,
          ev?.metaKey ? 1 : 0,
          Number(ev?.clientX ?? 0) | 0,
          Number(ev?.clientY ?? 0) | 0,
          Number(ev?.button ?? 0) | 0,
          options.capture ? 1 : 0,
          extrasBuf.ptr,
          extrasBuf.len
        ));

        const bits = Number(flags ?? 0) | 0;
        if ((bits & 1) !== 0 && typeof ev?.preventDefault === "function") {
          ev.preventDefault();
        }
        if ((bits & 2) !== 0 && typeof ev?.stopPropagation === "function") {
          ev.stopPropagation();
        }
      } finally {
        valueBuf.free();
        keyBuf.free();
        extrasBuf.free();
        if (options.once) {
          listeners.delete(key);
        }
      }
    };

    if (typeof node.addEventListener === "function") {
      node.addEventListener(eventName, handler, options);
      listeners.set(key, { node, eventName, handler, options });
    }
  }

  function removeListener(nodeId, eventCode, optionsMask) {
    const options = decodeOptionsMask(optionsMask);
    const key = listenerKey(nodeId, eventCode, options.capture);
    const entry = listeners.get(key);
    if (!entry) {
      return;
    }
    if (entry?.node && typeof entry.node.removeEventListener === "function") {
      entry.node.removeEventListener(entry.eventName, entry.handler, { capture: options.capture });
    }
    listeners.delete(key);
  }

  function setDomAttr(node, name, value, kindCode) {
    const kind = Number(kindCode) | 0;

    if (kind === 2) {
      if (node?.style && typeof node.style.setProperty === "function") {
        node.style.setProperty(name, String(value ?? ""));
      }
      return;
    }

    if (kind === 1) {
      if (name === "__nimui_ref") {
        return;
      }
      if (name === "value") {
        node.value = String(value ?? "");
        return;
      }
      if (BOOLEAN_PROPS.has(name)) {
        node[name] = normalizeBool(value);
        return;
      }
      node[name] = value;
      return;
    }

    if (typeof node.setAttribute === "function") {
      node.setAttribute(name, String(value ?? ""));
    }
  }

  function removeDomAttr(node, name, kindCode) {
    const kind = Number(kindCode) | 0;

    if (kind === 2) {
      if (node?.style && typeof node.style.removeProperty === "function") {
        node.style.removeProperty(name);
      }
      return;
    }

    if (kind === 1) {
      if (name === "__nimui_ref") {
        return;
      }
      if (name === "value") {
        node.value = "";
      } else if (BOOLEAN_PROPS.has(name)) {
        node[name] = false;
      } else {
        try {
          node[name] = undefined;
        } catch (_) {
          // ignore property removal failures
        }
      }
      return;
    }

    if (typeof node.removeAttribute === "function") {
      node.removeAttribute(name);
    }
  }

  function emitFetchResolve(requestId, response) {
    const fn = instance?.exports?.nimui_net_fetch_resolve;
    if (typeof fn !== "function") {
      return;
    }

    const statusTextBuf = allocString(response?.statusText ?? "");
    const bodyBuf = allocString(response?.body ?? "");
    const headersBuf = allocString(encodePairsBlob(response?.headers ?? []));
    try {
      safeInvoke("nimui_net_fetch_resolve", () => fn(
        Number(requestId) | 0,
        Number(response?.status ?? 0) | 0,
        response?.ok ? 1 : 0,
        statusTextBuf.ptr,
        statusTextBuf.len,
        bodyBuf.ptr,
        bodyBuf.len,
        headersBuf.ptr,
        headersBuf.len
      ));
    } finally {
      statusTextBuf.free();
      bodyBuf.free();
      headersBuf.free();
    }
  }

  function emitFetchReject(requestId, message) {
    const fn = instance?.exports?.nimui_net_fetch_reject;
    if (typeof fn !== "function") {
      return;
    }
    const messageBuf = allocString(message ?? "");
    try {
      safeInvoke("nimui_net_fetch_reject", () => fn(
        Number(requestId) | 0,
        messageBuf.ptr,
        messageBuf.len
      ));
    } finally {
      messageBuf.free();
    }
  }

  function emitWsOpen(connectionId) {
    const fn = instance?.exports?.nimui_net_ws_open;
    if (typeof fn === "function") {
      safeInvoke("nimui_net_ws_open", () => fn(Number(connectionId) | 0));
    }
  }

  function emitWsMessage(connectionId, data) {
    const fn = instance?.exports?.nimui_net_ws_message;
    if (typeof fn !== "function") {
      return;
    }
    const dataBuf = allocString(data ?? "");
    try {
      safeInvoke("nimui_net_ws_message", () => fn(
        Number(connectionId) | 0,
        dataBuf.ptr,
        dataBuf.len
      ));
    } finally {
      dataBuf.free();
    }
  }

  function emitWsError(connectionId, message) {
    const fn = instance?.exports?.nimui_net_ws_error;
    if (typeof fn !== "function") {
      return;
    }
    const messageBuf = allocString(message ?? "");
    try {
      safeInvoke("nimui_net_ws_error", () => fn(
        Number(connectionId) | 0,
        messageBuf.ptr,
        messageBuf.len
      ));
    } finally {
      messageBuf.free();
    }
  }

  function emitWsClose(connectionId, code, wasClean, reason) {
    const fn = instance?.exports?.nimui_net_ws_closed;
    if (typeof fn !== "function") {
      return;
    }
    const reasonBuf = allocString(reason ?? "");
    try {
      safeInvoke("nimui_net_ws_closed", () => fn(
        Number(connectionId) | 0,
        Number(code) | 0,
        wasClean ? 1 : 0,
        reasonBuf.ptr,
        reasonBuf.len
      ));
    } finally {
      reasonBuf.free();
    }
  }

  function emitSseOpen(streamId) {
    const fn = instance?.exports?.nimui_net_sse_open;
    if (typeof fn === "function") {
      safeInvoke("nimui_net_sse_open", () => fn(Number(streamId) | 0));
    }
  }

  function emitSseMessage(streamId, eventName, data, lastEventId) {
    const fn = instance?.exports?.nimui_net_sse_message;
    if (typeof fn !== "function") {
      return;
    }
    const eventNameBuf = allocString(eventName ?? "");
    const dataBuf = allocString(data ?? "");
    const lastIdBuf = allocString(lastEventId ?? "");
    try {
      safeInvoke("nimui_net_sse_message", () => fn(
        Number(streamId) | 0,
        eventNameBuf.ptr,
        eventNameBuf.len,
        dataBuf.ptr,
        dataBuf.len,
        lastIdBuf.ptr,
        lastIdBuf.len
      ));
    } finally {
      eventNameBuf.free();
      dataBuf.free();
      lastIdBuf.free();
    }
  }

  function emitSseError(streamId, message) {
    const fn = instance?.exports?.nimui_net_sse_error;
    if (typeof fn !== "function") {
      return;
    }
    const messageBuf = allocString(message ?? "");
    try {
      safeInvoke("nimui_net_sse_error", () => fn(
        Number(streamId) | 0,
        messageBuf.ptr,
        messageBuf.len
      ));
    } finally {
      messageBuf.free();
    }
  }

  function emitSseClosed(streamId) {
    const fn = instance?.exports?.nimui_net_sse_closed;
    if (typeof fn === "function") {
      safeInvoke("nimui_net_sse_closed", () => fn(Number(streamId) | 0));
    }
  }

  function wsPayloadToString(data) {
    if (typeof data === "string") {
      return data;
    }
    if (data instanceof ArrayBuffer) {
      return decoder.decode(new Uint8Array(data));
    }
    if (ArrayBuffer.isView(data)) {
      return decoder.decode(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
    }
    if (data && typeof data === "object" && typeof data.text === "function") {
      return null;
    }
    return String(data ?? "");
  }

  const imports = {
    realloc(ptr, size) {
      return reallocImpl(ptr, size);
    },

    malloc(size) {
      return mallocImpl(size);
    },

    free(ptr) {
      freeImpl(ptr);
    },

    calloc(count, size) {
      return callocImpl(count, size);
    },

    memcmp(aPtr, bPtr, len) {
      return memcmpImpl(aPtr, bPtr, len);
    },

    memchr(ptr, ch, len) {
      return memchrImpl(ptr, ch, len);
    },

    strtod(nptr, endPtrPtr) {
      return strtodImpl(nptr, endPtrPtr);
    },

    nimui_mount_root(rootId, selPtr, selLen) {
      const selector = readString(selPtr, selLen) || "#app";
      const root = doc.querySelector(selector);
      if (!root) {
        throw new Error(`mount root not found for selector ${selector}`);
      }
      registerNode(rootId, root);
      return rootId;
    },

    nimui_unmount_root(rootId) {
      const root = nodes.get(rootId);
      if (!root) {
        return;
      }
      cleanupManagedSubtree(root);
      forgetNode(rootId, root);
    },

    nimui_create_element(nodeId, tagPtr, tagLen) {
      const tag = readString(tagPtr, tagLen) || "div";
      registerNode(nodeId, doc.createElement(tag));
    },

    nimui_create_text(nodeId, txtPtr, txtLen) {
      registerNode(nodeId, doc.createTextNode(readString(txtPtr, txtLen)));
    },

    nimui_append_child(parentId, childId) {
      ensureNode(parentId).appendChild(ensureNode(childId));
    },

    nimui_insert_before(parentId, childId, refChildId) {
      const parent = ensureNode(parentId);
      const child = ensureNode(childId);
      const refNode = refChildId ? nodes.get(refChildId) : null;
      parent.insertBefore(child, refNode ?? null);
    },

    nimui_remove_node(nodeId) {
      const node = nodes.get(nodeId);
      if (!node) {
        return;
      }
      cleanupManagedSubtree(node);
      if (node.parentNode) {
        node.parentNode.removeChild(node);
      }
    },

    nimui_set_text(nodeId, txtPtr, txtLen) {
      const node = ensureNode(nodeId);
      const value = readString(txtPtr, txtLen);
      if ("nodeValue" in node) {
        node.nodeValue = value;
      } else {
        node.textContent = value;
      }
    },

    nimui_set_attr(nodeId, namePtr, nameLen, valPtr, valLen, kindCode) {
      const node = ensureNode(nodeId);
      const name = readString(namePtr, nameLen);
      const value = readString(valPtr, valLen);
      setDomAttr(node, name, value, kindCode);
    },

    nimui_remove_attr(nodeId, namePtr, nameLen, kindCode) {
      const node = ensureNode(nodeId);
      const name = readString(namePtr, nameLen);
      removeDomAttr(node, name, kindCode);
    },

    nimui_add_event_listener(nodeId, eventCode, optionsMask) {
      addListener(nodeId, eventCode, optionsMask);
    },

    nimui_remove_event_listener(nodeId, eventCode, optionsMask) {
      removeListener(nodeId, eventCode, optionsMask);
    },

    nimui_hydrate_begin(rootId) {
      hydrationActive = true;
      hydrationRootId = Number(rootId) | 0;
      hydrationCursorByParent.clear();
      setNimHydrationError("");
    },

    nimui_hydrate_end(rootId) {
      const targetRootId = Number(rootId) | 0;
      const rootNode = nodes.get(targetRootId);
      if (rootNode) {
        removeUnmanagedSubtree(rootNode);
      }
      hydrationActive = false;
      hydrationRootId = 0;
      hydrationCursorByParent.clear();
    },

    nimui_hydrate_element(nodeId, parentId, tagPtr, tagLen) {
      const parent = ensureNode(parentId);
      const tag = readString(tagPtr, tagLen) || "div";

      if (!hydrationActive) {
        const created = doc.createElement(tag);
        registerNode(nodeId, created);
        parent.appendChild(created);
        return;
      }

      const candidate = nextHydrationCandidate(parentId);
      const matchesCandidate =
        candidate &&
        candidate.nodeType === 1 &&
        String(candidate.tagName || "").toLowerCase() === tag.toLowerCase() &&
        !nodeToId.has(candidate);

      if (matchesCandidate) {
        registerNode(nodeId, candidate);
        return;
      }

      reportHydrationMismatch(
        `element mismatch under parent ${parentId}: expected <${tag}>`
      );
      const created = doc.createElement(tag);
      registerNode(nodeId, created);
      if (candidate && candidate.parentNode === parent) {
        parent.insertBefore(created, candidate);
        parent.removeChild(candidate);
      } else {
        parent.appendChild(created);
      }
    },

    nimui_hydrate_text(nodeId, parentId, txtPtr, txtLen) {
      const parent = ensureNode(parentId);
      const txt = readString(txtPtr, txtLen);

      if (!hydrationActive) {
        const created = doc.createTextNode(txt);
        registerNode(nodeId, created);
        parent.appendChild(created);
        return;
      }

      const candidate = nextHydrationCandidate(parentId);
      const matchesCandidate =
        candidate &&
        candidate.nodeType === 3 &&
        !nodeToId.has(candidate);

      if (matchesCandidate) {
        registerNode(nodeId, candidate);
        if (candidate.nodeValue !== txt) {
          reportHydrationMismatch(
            `text mismatch under parent ${parentId}: expected '${txt}'`
          );
          candidate.nodeValue = txt;
        }
        return;
      }

      reportHydrationMismatch(
        `text node mismatch under parent ${parentId}`
      );
      const created = doc.createTextNode(txt);
      registerNode(nodeId, created);
      if (candidate && candidate.parentNode === parent) {
        parent.insertBefore(created, candidate);
        parent.removeChild(candidate);
      } else {
        parent.appendChild(created);
      }
    },

    nimui_net_fetch(requestId, urlPtr, urlLen, methodPtr, methodLen, headersPtr, headersLen, bodyPtr, bodyLen, responseModeCode) {
      const fetchFn = globalThis.fetch;
      if (typeof fetchFn !== "function") {
        emitFetchReject(requestId, "fetch is not available in this runtime");
        return;
      }

      const url = readString(urlPtr, urlLen);
      const method = readString(methodPtr, methodLen) || "GET";
      const body = readString(bodyPtr, bodyLen);
      const responseMode = Number(responseModeCode) | 0;
      const requestHeaderPairs = parsePairsBlob(readString(headersPtr, headersLen));
      const requestHeaders = {};
      for (const [name, value] of requestHeaderPairs) {
        requestHeaders[name] = value;
      }

      const init = { method };
      const AbortControllerCtor = globalThis.AbortController;
      let controller = null;
      if (typeof AbortControllerCtor === "function") {
        controller = new AbortControllerCtor();
        init.signal = controller.signal;
      }
      if (requestHeaderPairs.length > 0) {
        init.headers = requestHeaders;
      }
      if (body.length > 0 || (method !== "GET" && method !== "HEAD")) {
        init.body = body;
      }
      if (controller) {
        fetchControllers.set(requestId, controller);
      }

      Promise.resolve()
        .then(() => fetchFn(url, init))
        .then(async (response) => {
          fetchControllers.delete(requestId);
          let payloadBody = "";
          if (responseMode === 2) {
            const binaryBody = new Uint8Array(await response.arrayBuffer());
            payloadBody = bytesToBase64(binaryBody);
          } else {
            payloadBody = await response.text();
          }
          emitFetchResolve(requestId, {
            status: Number(response?.status ?? 0) | 0,
            statusText: String(response?.statusText ?? ""),
            ok: !!response?.ok,
            body: payloadBody,
            headers: responseHeaderPairs(response?.headers)
          });
        })
        .catch((err) => {
          fetchControllers.delete(requestId);
          emitFetchReject(requestId, err?.message || String(err));
        });
    },

    nimui_net_fetch_abort(requestId) {
      const id = Number(requestId) | 0;
      const controller = fetchControllers.get(id);
      if (!controller) {
        return 0;
      }
      fetchControllers.delete(id);
      try {
        controller.abort();
        return 1;
      } catch (_) {
        return 0;
      }
    },

    nimui_net_ws_connect(connectionId, urlPtr, urlLen) {
      const WsCtor = globalThis.WebSocket;
      if (typeof WsCtor !== "function") {
        emitWsError(connectionId, "WebSocket is not available in this runtime");
        emitWsClose(connectionId, 1006, false, "WebSocket unavailable");
        return 0;
      }

      const url = readString(urlPtr, urlLen);
      try {
        const ws = new WsCtor(url);
        try {
          ws.binaryType = "arraybuffer";
        } catch (_) {
          // ignore runtimes that reject binaryType mutation
        }

        ws.addEventListener("open", () => {
          emitWsOpen(connectionId);
        });

        ws.addEventListener("message", (ev) => {
          const payload = wsPayloadToString(ev?.data);
          if (payload !== null) {
            emitWsMessage(connectionId, payload);
            return;
          }
          Promise.resolve(ev?.data?.text?.())
            .then((text) => emitWsMessage(connectionId, String(text ?? "")))
            .catch((err) => emitWsError(connectionId, err?.message || String(err)));
        });

        ws.addEventListener("error", () => {
          emitWsError(connectionId, "websocket error");
        });

        ws.addEventListener("close", (ev) => {
          wsSockets.delete(connectionId);
          emitWsClose(
            connectionId,
            Number(ev?.code ?? 1000) | 0,
            !!ev?.wasClean,
            String(ev?.reason ?? "")
          );
        });

        wsSockets.set(connectionId, ws);
        return 1;
      } catch (err) {
        emitWsError(connectionId, err?.message || String(err));
        emitWsClose(connectionId, 1006, false, "WebSocket connection setup failed");
        return 0;
      }
    },

    nimui_net_ws_send(connectionId, dataPtr, dataLen) {
      const ws = wsSockets.get(connectionId);
      if (!ws) {
        return 0;
      }
      const data = readString(dataPtr, dataLen);
      try {
        ws.send(data);
        return 1;
      } catch (err) {
        emitWsError(connectionId, err?.message || String(err));
        return 0;
      }
    },

    nimui_net_ws_close(connectionId, code, reasonPtr, reasonLen) {
      const ws = wsSockets.get(connectionId);
      if (!ws) {
        return 0;
      }
      const reason = readString(reasonPtr, reasonLen);
      try {
        ws.close(Number(code) | 0, reason);
        return 1;
      } catch (err) {
        emitWsError(connectionId, err?.message || String(err));
        return 0;
      }
    },

    nimui_net_sse_connect(streamId, urlPtr, urlLen, withCredentials) {
      const EventSourceCtor = globalThis.EventSource;
      if (typeof EventSourceCtor !== "function") {
        emitSseError(streamId, "EventSource is not available in this runtime");
        return 0;
      }

      const url = readString(urlPtr, urlLen);
      try {
        const stream = new EventSourceCtor(url, {
          withCredentials: withCredentials !== 0
        });

        stream.addEventListener("open", () => {
          emitSseOpen(streamId);
        });

        stream.addEventListener("message", (ev) => {
          emitSseMessage(
            streamId,
            String(ev?.type ?? "message"),
            String(ev?.data ?? ""),
            String(ev?.lastEventId ?? "")
          );
        });

        stream.addEventListener("error", () => {
          emitSseError(streamId, "sse error");
        });

        sseStreams.set(streamId, stream);
        return 1;
      } catch (err) {
        emitSseError(streamId, err?.message || String(err));
        return 0;
      }
    },

    nimui_net_sse_close(streamId) {
      const stream = sseStreams.get(streamId);
      if (!stream) {
        return 0;
      }
      sseStreams.delete(streamId);
      try {
        stream.close();
        emitSseClosed(streamId);
        return 1;
      } catch (err) {
        emitSseError(streamId, err?.message || String(err));
        return 0;
      }
    },

    nimui_runtime_panic(msgPtr, msgLen) {
      pendingPanicError = readString(msgPtr, msgLen) || "panic";
    },

    nimui_schedule_flush() {
      if (flushQueued || fatalError) {
        return;
      }
      flushQueued = true;
      queueFlush(() => {
        flushQueued = false;
        if (instance?.exports?.nimui_flush) {
          safeInvoke("nimui_flush", () => instance.exports.nimui_flush());
          emitRuntimeEventFromNim();
        }
      });
    },

    nimui_location_path_len() {
      const loc = globalThis.location;
      const value = `${loc?.pathname ?? "/"}${loc?.search ?? ""}`;
      return encoder.encode(value).length;
    },

    nimui_location_path_copy(dst, cap) {
      const loc = globalThis.location;
      const value = `${loc?.pathname ?? "/"}${loc?.search ?? ""}`;
      return writeStringToMemory(value, dst, cap);
    },

    nimui_location_origin_len() {
      const loc = globalThis.location;
      const value = String(loc?.origin ?? "");
      return encoder.encode(value).length;
    },

    nimui_location_origin_copy(dst, cap) {
      const loc = globalThis.location;
      const value = String(loc?.origin ?? "");
      return writeStringToMemory(value, dst, cap);
    },

    nimui_history_push(pathPtr, pathLen) {
      const path = readString(pathPtr, pathLen) || "/";
      const historyRef = globalThis.history;
      if (historyRef && typeof historyRef.pushState === "function") {
        historyRef.pushState({}, "", path);
      }
    },

    nimui_history_replace(pathPtr, pathLen) {
      const path = readString(pathPtr, pathLen) || "/";
      const historyRef = globalThis.history;
      if (historyRef && typeof historyRef.replaceState === "function") {
        historyRef.replaceState({}, "", path);
      }
    },

    nimui_history_subscribe() {
      if (historySubscribed) {
        return;
      }
      historySubscribed = true;
      if (typeof globalThis.addEventListener === "function") {
        globalThis.addEventListener("popstate", () => {
          if (instance?.exports?.nimui_route_changed) {
            safeInvoke("nimui_route_changed", () => instance.exports.nimui_route_changed());
          }
        });
      }
    }
  };

  function start(selector = "#app") {
    if (!instance?.exports?.nimui_start) {
      throw new Error("nimui_start export missing");
    }
    const selectorBuf = allocString(selector);
    try {
      safeInvoke("nimui_start", () => instance.exports.nimui_start(selectorBuf.ptr, selectorBuf.len));
      emitRuntimeEventFromNim();
    } finally {
      selectorBuf.free();
    }
  }

  function hydrate(selector = "#app") {
    if (typeof instance?.exports?.nimui_hydrate !== "function") {
      start(selector);
      return;
    }
    const selectorBuf = allocString(selector);
    try {
      safeInvoke("nimui_hydrate", () => instance.exports.nimui_hydrate(selectorBuf.ptr, selectorBuf.len));
      emitRuntimeEventFromNim();
    } finally {
      selectorBuf.free();
    }
  }

  function refresh() {
    if (typeof instance?.exports?.nimui_refresh === "function") {
      safeInvoke("nimui_refresh", () => instance.exports.nimui_refresh());
      emitRuntimeEventFromNim();
      return;
    }
    if (typeof instance?.exports?.nimui_unmount === "function") {
      safeInvoke("nimui_unmount", () => instance.exports.nimui_unmount());
    }
    start("#app");
  }

  return {
    imports,
    bindInstance,
    allocString,
    start,
    hydrate,
    refresh,
    safeInvoke,
    getFatalError() {
      return fatalError;
    },
    getNode(id) {
      return nodes.get(id);
    },
    nodes,
    listeners,
    wsSockets,
    sseStreams
  };
}
