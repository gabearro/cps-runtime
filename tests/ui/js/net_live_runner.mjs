import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { connect as netConnect } from "node:net";
import { connect as tlsConnect } from "node:tls";
import { loadNimUiWasm } from "../../../src/cps/ui/js/loader.js";

class FakeNode {
  constructor(ownerDocument) {
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.childNodes = [];
  }

  appendChild(node) {
    if (node.parentNode) {
      node.parentNode.removeChild(node);
    }
    node.parentNode = this;
    this.childNodes.push(node);
    return node;
  }

  insertBefore(node, refNode) {
    if (!refNode) {
      return this.appendChild(node);
    }
    const idx = this.childNodes.indexOf(refNode);
    if (idx < 0) {
      return this.appendChild(node);
    }
    if (node.parentNode) {
      node.parentNode.removeChild(node);
    }
    node.parentNode = this;
    this.childNodes.splice(idx, 0, node);
    return node;
  }

  removeChild(node) {
    const idx = this.childNodes.indexOf(node);
    if (idx >= 0) {
      this.childNodes.splice(idx, 1);
      node.parentNode = null;
    }
    return node;
  }

  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }

  set textContent(value) {
    this.childNodes = [];
    if (value !== "") {
      this.appendChild(new FakeText(this.ownerDocument, String(value)));
    }
  }
}

class FakeText extends FakeNode {
  constructor(ownerDocument, value = "") {
    super(ownerDocument);
    this.nodeValue = value;
  }

  get textContent() {
    return this.nodeValue;
  }

  set textContent(value) {
    this.nodeValue = String(value);
  }
}

class FakeElement extends FakeNode {
  constructor(ownerDocument, tagName) {
    super(ownerDocument);
    this.tagName = tagName.toLowerCase();
    this.attributes = new Map();
    this.listeners = new Map();
    this.styleMap = new Map();
    this.style = {
      setProperty: (name, value) => {
        this.styleMap.set(String(name), String(value));
      },
      removeProperty: (name) => {
        this.styleMap.delete(String(name));
      }
    };
  }

  setAttribute(name, value) {
    const val = String(value);
    this.attributes.set(name, val);
    if (name === "id") {
      this.ownerDocument.idMap.set(val, this);
    }
  }

  removeAttribute(name) {
    if (name === "id") {
      const currentId = this.attributes.get("id");
      if (currentId) {
        this.ownerDocument.idMap.delete(currentId);
      }
    }
    this.attributes.delete(name);
  }

  addEventListener(type, handler) {
    let arr = this.listeners.get(type);
    if (!arr) {
      arr = [];
      this.listeners.set(type, arr);
    }
    arr.push(handler);
  }

  removeEventListener(type, handler) {
    const arr = this.listeners.get(type);
    if (!arr) {
      return;
    }
    const idx = arr.indexOf(handler);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  }
}

class FakeDocument {
  constructor() {
    this.idMap = new Map();
    this.body = new FakeElement(this, "body");
  }

  createElement(tagName) {
    return new FakeElement(this, tagName);
  }

  createTextNode(value) {
    return new FakeText(this, value);
  }

  querySelector(selector) {
    if (selector.startsWith("#")) {
      return this.idMap.get(selector.slice(1)) ?? null;
    }
    const tag = selector.toLowerCase();
    const queue = [...this.body.childNodes];
    while (queue.length > 0) {
      const node = queue.shift();
      if (node instanceof FakeElement && node.tagName === tag) {
        return node;
      }
      queue.push(...node.childNodes);
    }
    return null;
  }
}

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

class NodeRawWebSocket {
  constructor(url) {
    this.url = String(url ?? "");
    this.readyState = 0; // CONNECTING
    this.binaryType = "arraybuffer";
    this.listeners = new Map();

    this.socket = null;
    this.handshakeComplete = false;
    this.input = Buffer.alloc(0);
    this.closeEmitted = false;
    this.closeSent = false;
    this.expectedAccept = "";
    this.closeInfo = { code: 1000, reason: "", wasClean: true };

    this.connect();
  }

  addEventListener(type, handler) {
    let arr = this.listeners.get(type);
    if (!arr) {
      arr = [];
      this.listeners.set(type, arr);
    }
    arr.push(handler);
  }

  removeEventListener(type, handler) {
    const arr = this.listeners.get(type);
    if (!arr) {
      return;
    }
    const idx = arr.indexOf(handler);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  }

  dispatchEvent(event) {
    const ev = event ?? {};
    const arr = [...(this.listeners.get(ev.type) ?? [])];
    for (const handler of arr) {
      handler(ev);
    }
  }

  connect() {
    let parsed;
    try {
      parsed = new URL(this.url);
    } catch (err) {
      queueMicrotask(() => {
        this.emitError(err?.message || String(err));
        this.emitClose(1006, false, "invalid websocket URL");
      });
      return;
    }

    const secure = parsed.protocol === "wss:";
    if (!secure && parsed.protocol !== "ws:") {
      queueMicrotask(() => {
        this.emitError(`unsupported websocket protocol: ${parsed.protocol}`);
        this.emitClose(1006, false, "unsupported protocol");
      });
      return;
    }

    const port = parsed.port ? Number(parsed.port) : secure ? 443 : 80;
    const host = parsed.hostname;
    const path = `${parsed.pathname || "/"}${parsed.search || ""}`;
    const wsKey = randomBytes(16).toString("base64");
    this.expectedAccept = createHash("sha1").update(wsKey + WS_GUID).digest("base64");

    const socket = secure
      ? tlsConnect({
          host,
          port,
          servername: host
        })
      : netConnect({ host, port });

    this.socket = socket;
    socket.setNoDelay(true);

    socket.on("connect", () => {
      const requestLines = [
        `GET ${path} HTTP/1.1`,
        `Host: ${parsed.host}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${wsKey}`,
        "Sec-WebSocket-Version: 13",
        "",
        ""
      ];
      socket.write(requestLines.join("\r\n"));
    });

    socket.on("data", (chunk) => {
      this.input = Buffer.concat([this.input, Buffer.from(chunk)]);
      this.processInput();
    });

    socket.on("error", (err) => {
      this.emitError(err?.message || String(err));
      this.emitClose(1006, false, "socket error");
    });

    socket.on("close", () => {
      this.readyState = 3; // CLOSED
      this.emitClose(this.closeInfo.code, this.closeInfo.wasClean, this.closeInfo.reason);
    });
  }

  processInput() {
    if (!this.handshakeComplete) {
      const headerEnd = this.input.indexOf("\r\n\r\n");
      if (headerEnd < 0) {
        return;
      }

      const responseText = this.input.slice(0, headerEnd).toString("utf8");
      this.input = this.input.slice(headerEnd + 4);

      if (!this.finishHandshake(responseText)) {
        return;
      }
    }

    this.consumeFrames();
  }

  finishHandshake(responseText) {
    const lines = responseText.split("\r\n");
    const statusLine = lines[0] ?? "";
    if (!statusLine.includes("101")) {
      this.emitError(`websocket handshake failed: ${statusLine}`);
      this.closeInfo = { code: 1006, reason: "handshake failed", wasClean: false };
      this.socket?.destroy();
      return false;
    }

    const headers = new Map();
    for (let i = 1; i < lines.length; i += 1) {
      const line = lines[i];
      const sep = line.indexOf(":");
      if (sep < 0) {
        continue;
      }
      const name = line.slice(0, sep).trim().toLowerCase();
      const value = line.slice(sep + 1).trim();
      headers.set(name, value);
    }

    const accept = headers.get("sec-websocket-accept");
    if (accept !== this.expectedAccept) {
      this.emitError("invalid Sec-WebSocket-Accept during handshake");
      this.closeInfo = { code: 1006, reason: "invalid handshake", wasClean: false };
      this.socket?.destroy();
      return false;
    }

    this.handshakeComplete = true;
    this.readyState = 1; // OPEN
    this.dispatchEvent({ type: "open" });
    return true;
  }

  consumeFrames() {
    while (true) {
      if (this.input.length < 2) {
        return;
      }

      const first = this.input[0];
      const second = this.input[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;

      let offset = 2;
      let payloadLen = second & 0x7f;

      if (payloadLen === 126) {
        if (this.input.length < offset + 2) {
          return;
        }
        payloadLen = this.input.readUInt16BE(offset);
        offset += 2;
      } else if (payloadLen === 127) {
        if (this.input.length < offset + 8) {
          return;
        }
        const big = this.input.readBigUInt64BE(offset);
        if (big > BigInt(Number.MAX_SAFE_INTEGER)) {
          this.emitError("frame too large");
          this.closeInfo = { code: 1009, reason: "frame too large", wasClean: false };
          this.socket?.destroy();
          return;
        }
        payloadLen = Number(big);
        offset += 8;
      }

      let mask = null;
      if (masked) {
        if (this.input.length < offset + 4) {
          return;
        }
        mask = this.input.slice(offset, offset + 4);
        offset += 4;
      }

      if (this.input.length < offset + payloadLen) {
        return;
      }

      const payload = Buffer.from(this.input.slice(offset, offset + payloadLen));
      this.input = this.input.slice(offset + payloadLen);

      if (mask) {
        for (let i = 0; i < payload.length; i += 1) {
          payload[i] ^= mask[i % 4];
        }
      }

      this.handleFrame(opcode, payload);
    }
  }

  handleFrame(opcode, payload) {
    if (opcode === 0x1) {
      this.dispatchEvent({ type: "message", data: payload.toString("utf8") });
      return;
    }

    if (opcode === 0x2) {
      const view = payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength);
      this.dispatchEvent({ type: "message", data: view });
      return;
    }

    if (opcode === 0x8) {
      let code = 1000;
      let reason = "";
      if (payload.length >= 2) {
        code = payload.readUInt16BE(0);
        reason = payload.slice(2).toString("utf8");
      }

      this.closeInfo = { code, reason, wasClean: true };
      if (!this.closeSent) {
        this.closeSent = true;
        this.writeFrame(0x8, payload);
      }
      this.readyState = 2; // CLOSING
      this.socket?.end();
      return;
    }

    if (opcode === 0x9) {
      this.writeFrame(0xA, payload);
    }
  }

  buildClientFrame(opcode, payload) {
    const body = Buffer.from(payload ?? Buffer.alloc(0));
    const len = body.length;
    const parts = [];
    const first = 0x80 | (opcode & 0x0f); // FIN + opcode
    parts.push(Buffer.from([first]));

    if (len < 126) {
      parts.push(Buffer.from([0x80 | len]));
    } else if (len <= 0xffff) {
      const hdr = Buffer.alloc(3);
      hdr[0] = 0x80 | 126;
      hdr.writeUInt16BE(len, 1);
      parts.push(hdr);
    } else {
      const hdr = Buffer.alloc(9);
      hdr[0] = 0x80 | 127;
      hdr.writeBigUInt64BE(BigInt(len), 1);
      parts.push(hdr);
    }

    const mask = randomBytes(4);
    const masked = Buffer.from(body);
    for (let i = 0; i < masked.length; i += 1) {
      masked[i] ^= mask[i % 4];
    }
    parts.push(mask, masked);
    return Buffer.concat(parts);
  }

  writeFrame(opcode, payload) {
    if (!this.socket || this.socket.destroyed) {
      return;
    }
    this.socket.write(this.buildClientFrame(opcode, payload));
  }

  send(data) {
    if (this.readyState !== 1) {
      throw new Error("socket not open");
    }
    const payload = Buffer.from(String(data ?? ""), "utf8");
    this.writeFrame(0x1, payload);
  }

  close(code = 1000, reason = "") {
    if (this.readyState === 3) {
      return;
    }
    if (this.readyState === 0) {
      this.readyState = 3;
      this.emitClose(Number(code) | 0, true, String(reason ?? ""));
      this.socket?.destroy();
      return;
    }

    this.closeSent = true;
    this.readyState = 2; // CLOSING
    const reasonPayload = Buffer.from(String(reason ?? ""), "utf8");
    const payload = Buffer.alloc(2 + reasonPayload.length);
    payload.writeUInt16BE(Number(code) | 0, 0);
    reasonPayload.copy(payload, 2);
    this.closeInfo = { code: Number(code) | 0, reason: String(reason ?? ""), wasClean: true };
    this.writeFrame(0x8, payload);
    this.socket?.end();
  }

  emitError(message) {
    this.dispatchEvent({
      type: "error",
      message: String(message ?? "websocket error")
    });
  }

  emitClose(code, wasClean, reason) {
    if (this.closeEmitted) {
      return;
    }
    this.closeEmitted = true;
    this.readyState = 3;
    this.dispatchEvent({
      type: "close",
      code: Number(code) | 0,
      wasClean: !!wasClean,
      reason: String(reason ?? "")
    });
  }
}

class NodeEventSource {
  constructor(url) {
    this.url = String(url ?? "");
    this.listeners = new Map();
    this.controller = new AbortController();
    this.closed = false;
    this.start();
  }

  addEventListener(type, handler) {
    let arr = this.listeners.get(type);
    if (!arr) {
      arr = [];
      this.listeners.set(type, arr);
    }
    arr.push(handler);
  }

  removeEventListener(type, handler) {
    const arr = this.listeners.get(type);
    if (!arr) {
      return;
    }
    const idx = arr.indexOf(handler);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  }

  dispatchEvent(event) {
    const ev = event ?? {};
    const arr = [...(this.listeners.get(ev.type) ?? [])];
    for (const handler of arr) {
      handler(ev);
    }
  }

  async start() {
    try {
      const response = await fetch(this.url, {
        method: "GET",
        headers: { Accept: "text/event-stream" },
        signal: this.controller.signal
      });
      if (!response.ok || !response.body) {
        throw new Error(`SSE request failed: ${response.status}`);
      }

      this.dispatchEvent({ type: "open" });

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let eventName = "message";
      let lastEventId = "";
      let dataLines = [];

      while (!this.closed) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        buffer += decoder.decode(value, { stream: true });

        while (true) {
          const idx = buffer.indexOf("\n");
          if (idx < 0) {
            break;
          }

          let line = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 1);
          if (line.endsWith("\r")) {
            line = line.slice(0, -1);
          }

          if (line.length == 0) {
            if (dataLines.length > 0) {
              this.dispatchEvent({
                type: "message",
                event: eventName,
                data: dataLines.join("\n"),
                lastEventId
              });
            }
            eventName = "message";
            dataLines = [];
            continue;
          }

          if (line.startsWith(":")) {
            continue;
          }

          const sep = line.indexOf(":");
          const field = sep >= 0 ? line.slice(0, sep) : line;
          let valueText = sep >= 0 ? line.slice(sep + 1) : "";
          if (valueText.startsWith(" ")) {
            valueText = valueText.slice(1);
          }

          if (field === "event") {
            eventName = valueText;
          } else if (field === "data") {
            dataLines.push(valueText);
          } else if (field === "id") {
            lastEventId = valueText;
          }
        }
      }
    } catch (err) {
      if (!this.closed) {
        this.dispatchEvent({
          type: "error",
          message: err?.message || String(err)
        });
      }
    }
  }

  close() {
    this.closed = true;
    this.controller.abort();
  }
}

function buildFixtureDocument() {
  const doc = new FakeDocument();
  const appRoot = doc.createElement("div");
  appRoot.setAttribute("id", "app");
  doc.body.appendChild(appRoot);

  const modalRoot = doc.createElement("div");
  modalRoot.setAttribute("id", "modal-root");
  doc.body.appendChild(modalRoot);
  return doc;
}

function findByTestId(doc, testId) {
  const queue = [...(doc.body?.childNodes ?? [])];
  while (queue.length > 0) {
    const node = queue.shift();
    if (node instanceof FakeElement) {
      if (node.attributes.get("data-testid") === testId) {
        return node;
      }
    }
    queue.push(...(node?.childNodes ?? []));
  }
  return null;
}

function installBrowserGlobals(baseUrl) {
  const nativeFetch = globalThis.fetch ? globalThis.fetch.bind(globalThis) : null;
  const previous = {
    location: globalThis.location,
    history: globalThis.history,
    addEventListener: globalThis.addEventListener,
    removeEventListener: globalThis.removeEventListener,
    dispatchEvent: globalThis.dispatchEvent,
    WebSocket: globalThis.WebSocket,
    EventSource: globalThis.EventSource,
    fetch: globalThis.fetch
  };

  const listeners = new Map();
  const initial = new URL("/ui/net_demo.html", baseUrl);
  const locationState = {
    protocol: initial.protocol,
    host: initial.host,
    origin: initial.origin,
    pathname: initial.pathname,
    search: initial.search
  };

  const setPath = (path) => {
    const url = new URL(path || "/", baseUrl);
    locationState.protocol = url.protocol;
    locationState.host = url.host;
    locationState.origin = url.origin;
    locationState.pathname = url.pathname;
    locationState.search = url.search;
  };

  globalThis.location = locationState;
  globalThis.history = {
    pushState(_state, _title, url) {
      setPath(String(url || "/"));
    },
    replaceState(_state, _title, url) {
      setPath(String(url || "/"));
    }
  };
  globalThis.addEventListener = (type, handler) => {
    let arr = listeners.get(type);
    if (!arr) {
      arr = [];
      listeners.set(type, arr);
    }
    arr.push(handler);
  };
  globalThis.removeEventListener = (type, handler) => {
    const arr = listeners.get(type);
    if (!arr) {
      return;
    }
    const idx = arr.indexOf(handler);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  };
  globalThis.dispatchEvent = (event) => {
    const ev = event ?? {};
    const arr = listeners.get(ev.type) ?? [];
    for (const handler of arr) {
      handler(ev);
    }
    return true;
  };
  if (nativeFetch) {
    globalThis.fetch = (input, init) => {
      if (typeof input === "string" || input instanceof URL) {
        return nativeFetch(new URL(String(input), baseUrl), init);
      }

      if (typeof Request !== "undefined" && input instanceof Request) {
        const resolved = new URL(input.url, baseUrl);
        const request = new Request(resolved, input);
        return nativeFetch(request, init);
      }

      return nativeFetch(input, init);
    };
  }
  globalThis.WebSocket = NodeRawWebSocket;
  globalThis.EventSource = NodeEventSource;

  return {
    restore() {
      const restoreProp = (name, value) => {
        if (typeof value === "undefined") {
          delete globalThis[name];
        } else {
          globalThis[name] = value;
        }
      };

      restoreProp("location", previous.location);
      restoreProp("history", previous.history);
      restoreProp("addEventListener", previous.addEventListener);
      restoreProp("removeEventListener", previous.removeEventListener);
      restoreProp("dispatchEvent", previous.dispatchEvent);
      restoreProp("WebSocket", previous.WebSocket);
      restoreProp("EventSource", previous.EventSource);
      restoreProp("fetch", previous.fetch);
    }
  };
}

async function waitForValue(doc, testId, expected, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const node = findByTestId(doc, testId);
    if (node && node.textContent === expected) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const node = findByTestId(doc, testId);
  throw new Error(`timed out waiting for [${testId}] to equal '${expected}', got '${node?.textContent ?? "<missing>"}'`);
}

async function main() {
  const wasmPath = process.argv[2];
  const baseUrl = process.argv[3] ?? "http://127.0.0.1:8082";
  if (!wasmPath) {
    throw new Error("usage: node net_live_runner.mjs <path-to-wasm> [base-url]");
  }

  const doc = buildFixtureDocument();
  const globals = installBrowserGlobals(baseUrl);
  const runtimeErrors = [];
  try {
    const { instance, host } = await loadNimUiWasm(wasmPath, {
      selector: "#app",
      documentRef: doc,
      onRuntimeError(err) {
        runtimeErrors.push(err);
        console.error("nimui-runtime-error", err);
      }
    });

    await waitForValue(doc, "fetch-state", "200:fetch-ok:POST:ping");
    await waitForValue(doc, "ws-state", "echo:hello");
    await waitForValue(doc, "sse-state", "message:ready:sse-1");

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
    }
    assert.equal(host.listeners.size, 0, "listeners should be detached after unmount");
    assert.equal(runtimeErrors.length, 0, "runtime errors should be empty");
    console.log("PASS: net live runner (frontend wasm <-> real server routes)");
  } finally {
    globals.restore();
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
