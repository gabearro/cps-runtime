import assert from "node:assert/strict";
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
    this.value = "";
    this.checked = false;
    this.selected = false;
    this.disabled = false;
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

  normalizeListenerOptions(options) {
    if (typeof options === "boolean") {
      return { capture: options, passive: false, once: false };
    }
    return {
      capture: !!options?.capture,
      passive: !!options?.passive,
      once: !!options?.once
    };
  }

  addEventListener(type, handler, options) {
    const opts = this.normalizeListenerOptions(options);
    let arr = this.listeners.get(type);
    if (!arr) {
      arr = [];
      this.listeners.set(type, arr);
    }
    arr.push({ handler, ...opts });
  }

  removeEventListener(type, handler, options) {
    const opts = this.normalizeListenerOptions(options);
    const arr = this.listeners.get(type);
    if (!arr) {
      return;
    }
    const idx = arr.findIndex((entry) => entry.handler === handler && entry.capture === opts.capture);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  }

  dispatchEvent(event) {
    const ev = event ?? {};
    ev.target = this;
    if (typeof ev.preventDefault !== "function") {
      ev.preventDefault = () => {
        ev.defaultPrevented = true;
      };
    }
    if (typeof ev.stopPropagation !== "function") {
      ev.stopPropagation = () => {
        ev.propagationStopped = true;
      };
    }

    const arr = (this.listeners.get(ev.type) ?? []).slice();
    const ordered = [
      ...arr.filter((entry) => entry.capture),
      ...arr.filter((entry) => !entry.capture)
    ];
    for (const entry of ordered) {
      entry.handler(ev);
      if (entry.once) {
        this.removeEventListener(ev.type, entry.handler, { capture: entry.capture });
      }
    }
    return !ev.defaultPrevented;
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

function installFakeBrowserGlobals(initialPath = "/") {
  const previous = {
    location: globalThis.location,
    history: globalThis.history,
    addEventListener: globalThis.addEventListener,
    removeEventListener: globalThis.removeEventListener,
    dispatchEvent: globalThis.dispatchEvent
  };

  const listeners = new Map();
  const locationState = {
    pathname: "/",
    search: "",
    protocol: "http:",
    host: "nimui.local",
    origin: "http://nimui.local"
  };

  const setPath = (path) => {
    const url = new URL(path || "/", "http://nimui.local");
    locationState.protocol = url.protocol;
    locationState.host = url.host;
    locationState.origin = url.origin;
    locationState.pathname = url.pathname;
    locationState.search = url.search;
  };

  setPath(initialPath);

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

  return {
    setPath(path, popstate = false) {
      setPath(path);
      if (popstate) {
        globalThis.dispatchEvent({ type: "popstate" });
      }
    },
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
    }
  };
}

async function tick() {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function listItemTexts(doc) {
  const ul = doc.querySelector("ul");
  if (!ul) {
    return [];
  }
  return ul.childNodes.map((li) => li.textContent);
}

function allText(node) {
  if (!node) {
    return "";
  }
  if (!node.childNodes || node.childNodes.length === 0) {
    return String(node.textContent ?? "");
  }
  return node.childNodes.map((n) => allText(n)).join("");
}

function findByTestId(doc, testId) {
  if (!doc || !testId) {
    return null;
  }
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

async function waitForText(doc, testId, expected, attempts = 24) {
  for (let i = 0; i < attempts; i += 1) {
    const node = findByTestId(doc, testId);
    if (node && node.textContent === expected) {
      return node;
    }
    await tick();
  }
  const current = findByTestId(doc, testId)?.textContent ?? "<missing>";
  throw new Error(`timed out waiting for ${testId}='${expected}', got '${current}'`);
}

class FakeWebSocket {
  constructor(url) {
    this.url = String(url ?? "");
    this.readyState = 0;
    this.listeners = new Map();
    this.binaryType = "blob";

    setTimeout(() => {
      if (this.readyState !== 0) {
        return;
      }
      this.readyState = 1;
      this.dispatchEvent({ type: "open" });
    }, 0);
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

  send(data) {
    if (this.readyState !== 1) {
      throw new Error("socket not open");
    }
    const payload = String(data ?? "");
    setTimeout(() => {
      if (this.readyState !== 1) {
        return;
      }
      this.dispatchEvent({ type: "message", data: `echo:${payload}` });
    }, 0);
  }

  close(code = 1000, reason = "") {
    if (this.readyState === 3) {
      return;
    }
    this.readyState = 3;
    this.dispatchEvent({
      type: "close",
      code: Number(code) | 0,
      reason: String(reason ?? ""),
      wasClean: true
    });
  }
}

class FakeEventSource {
  constructor(url, opts = {}) {
    this.url = String(url ?? "");
    this.withCredentials = !!opts.withCredentials;
    this.closed = false;
    this.listeners = new Map();

    setTimeout(() => {
      if (this.closed) {
        return;
      }
      this.dispatchEvent({ type: "open" });
    }, 0);

    setTimeout(() => {
      if (this.closed) {
        return;
      }
      this.dispatchEvent({
        type: "message",
        data: "ready",
        lastEventId: "sse-1"
      });
    }, 0);
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

  close() {
    this.closed = true;
  }
}

function installFakeNetworkGlobals() {
  const previous = {
    fetch: globalThis.fetch,
    WebSocket: globalThis.WebSocket,
    EventSource: globalThis.EventSource
  };

  globalThis.fetch = async (input, init = {}) => {
    const requestUrl = String(input ?? "");
    const method = String(init?.method ?? "GET").toUpperCase();
    const body = String(init?.body ?? "");
    let payload = `fetch-ok:${method}:${body}`;
    let headerPairs = [
      ["content-type", "text/plain"],
      ["x-source", "fake-network"]
    ];
    let binaryPayload = null;

    if (requestUrl.includes("/api/net/json")) {
      payload = JSON.stringify({ mode: "json", ok: true });
      headerPairs = [
        ["content-type", "application/json"],
        ["x-source", "fake-network"]
      ];
    } else if (requestUrl.includes("/api/net/bytes")) {
      payload = "bytes";
      binaryPayload = new Uint8Array([98, 121, 116, 101, 115]); // "bytes"
      headerPairs = [
        ["content-type", "application/octet-stream"],
        ["x-source", "fake-network"]
      ];
    }

    const binaryView = binaryPayload ?? new TextEncoder().encode(payload);
    return {
      status: 200,
      statusText: "OK",
      ok: true,
      headers: {
        forEach(cb) {
          for (const [name, value] of headerPairs) {
            cb(value, name);
          }
        }
      },
      async text() {
        return payload;
      },
      async arrayBuffer() {
        return binaryView.buffer.slice(
          binaryView.byteOffset,
          binaryView.byteOffset + binaryView.byteLength
        );
      }
    };
  };

  globalThis.WebSocket = FakeWebSocket;
  globalThis.EventSource = FakeEventSource;

  return {
    restore() {
      const restoreProp = (name, value) => {
        if (typeof value === "undefined") {
          delete globalThis[name];
        } else {
          globalThis[name] = value;
        }
      };

      restoreProp("fetch", previous.fetch);
      restoreProp("WebSocket", previous.WebSocket);
      restoreProp("EventSource", previous.EventSource);
    }
  };
}

function assertHostAttrPropertySemantics(host) {
  const tagBuf = host.allocString("input");
  try {
    host.imports.nimui_create_element(9001, tagBuf.ptr, tagBuf.len);
  } finally {
    tagBuf.free();
  }

  const inputNode = host.getNode(9001);
  assert.ok(inputNode, "expected created input node");

  const nameValue = host.allocString("value");
  const valA = host.allocString("hello");
  try {
    host.imports.nimui_set_attr(9001, nameValue.ptr, nameValue.len, valA.ptr, valA.len, 1);
  } finally {
    nameValue.free();
    valA.free();
  }
  assert.equal(inputNode.value, "hello");

  const nameChecked = host.allocString("checked");
  const checkedTrue = host.allocString("true");
  try {
    host.imports.nimui_set_attr(9001, nameChecked.ptr, nameChecked.len, checkedTrue.ptr, checkedTrue.len, 1);
  } finally {
    nameChecked.free();
    checkedTrue.free();
  }
  assert.equal(inputNode.checked, true);

  const styleName = host.allocString("color");
  const styleVal = host.allocString("red");
  try {
    host.imports.nimui_set_attr(9001, styleName.ptr, styleName.len, styleVal.ptr, styleVal.len, 2);
  } finally {
    styleName.free();
    styleVal.free();
  }
  assert.equal(inputNode.styleMap.get("color"), "red");

  const rmChecked = host.allocString("checked");
  try {
    host.imports.nimui_remove_attr(9001, rmChecked.ptr, rmChecked.len, 1);
  } finally {
    rmChecked.free();
  }
  assert.equal(inputNode.checked, false);

  const rmStyle = host.allocString("color");
  try {
    host.imports.nimui_remove_attr(9001, rmStyle.ptr, rmStyle.len, 2);
  } finally {
    rmStyle.free();
  }
  assert.equal(inputNode.styleMap.has("color"), false);
}

async function runCounterScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  try {
    const doc = buildFixtureDocument();
    const { instance, host } = await loadNimUiWasm(wasmPath, { selector: "#app", documentRef: doc });

    const heading = doc.querySelector("h1");
    assert.ok(heading, "expected h1 node");
    assert.equal(heading.textContent, "Count: 0");

    const button = doc.querySelector("button");
    assert.ok(button, "expected button node");
    button.dispatchEvent({ type: "click", preventDefault() {} });
    await tick();
    await tick();

    assert.equal(heading.textContent, "Count: 1");

    assertHostAttrPropertySemantics(host);

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
      assert.equal(host.listeners.size, 0, "all listeners should be detached after unmount");
    }
  } finally {
    env.restore();
  }
}

async function runTodoScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  try {
    const doc = buildFixtureDocument();
    const { instance, host } = await loadNimUiWasm(wasmPath, { selector: "#app", documentRef: doc });

    assert.deepEqual(listItemTexts(doc), ["task-a", "task-b", "task-c"]);

    const modalRoot = doc.querySelector("#modal-root");
    assert.ok(modalRoot, "expected modal root");
    assert.ok(modalRoot.textContent.includes("normal"), "expected initial portal text in modal root");

    const button = doc.querySelector("button");
    assert.ok(button, "expected reorder button");
    button.dispatchEvent({ type: "click", preventDefault() {} });
    await tick();
    await tick();

    assert.deepEqual(listItemTexts(doc), ["task-c", "task-b", "task-a"]);
    assert.ok(modalRoot.textContent.includes("reversed"), "expected updated portal text in modal root");

    const appRoot = doc.querySelector("#app");
    assert.ok(appRoot.textContent.includes("Keyed Todo List"), "app root should remain mapped after portal updates");

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
      assert.equal(host.listeners.size, 0, "all listeners should be detached after unmount");
    }
  } finally {
    env.restore();
  }
}

async function runRouterScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  try {
    const doc = buildFixtureDocument();
    const { instance, host } = await loadNimUiWasm(wasmPath, { selector: "#app", documentRef: doc });

    const appRoot = doc.querySelector("#app");
    assert.ok(appRoot, "expected app root");
    assert.ok(allText(appRoot).includes("Home"), "expected home route");

    const link = doc.querySelector("a");
    assert.ok(link, "expected router link");
    link.dispatchEvent({ type: "click", preventDefault() {} });
    await tick();
    await tick();

    assert.ok(allText(appRoot).includes("User:42"), "expected user route after link navigation");
    assert.ok(allText(appRoot).includes("Tab:profile"), "expected query parsing in route render");

    env.setPath("/settings", true);
    await tick();
    await tick();

    assert.ok(allText(appRoot).includes("Settings"), "expected settings route after popstate");

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
      assert.equal(host.listeners.size, 0, "all listeners should be detached after router unmount");
    }
  } finally {
    env.restore();
  }
}

async function runControlledInputScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  try {
    const doc = buildFixtureDocument();
    const { instance, host } = await loadNimUiWasm(wasmPath, { selector: "#app", documentRef: doc });

    const input = doc.querySelector("input");
    const paragraph = doc.querySelector("p");
    assert.ok(input, "expected controlled input");
    assert.ok(paragraph, "expected controlled state text");
    assert.equal(paragraph.textContent, "hello|false");

    input.value = "nimui";
    input.dispatchEvent({ type: "input" });
    await tick();
    await tick();
    assert.equal(paragraph.textContent, "nimui|false");

    input.checked = true;
    input.dispatchEvent({ type: "change" });
    await tick();
    await tick();
    assert.equal(paragraph.textContent, "nimui|true");

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
      assert.equal(host.listeners.size, 0, "all listeners should be detached after controlled input unmount");
    }
  } finally {
    env.restore();
  }
}

async function runNetScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  const netEnv = installFakeNetworkGlobals();
  try {
    const doc = buildFixtureDocument();
    const { instance, host } = await loadNimUiWasm(wasmPath, { selector: "#app", documentRef: doc });

    const fetchNode = await waitForText(doc, "fetch-state", "200:fetch-ok:POST:ping");
    const fetchJsonNode = await waitForText(doc, "fetch-json-state", "json:true");
    const fetchBytesNode = await waitForText(doc, "fetch-bytes-state", "5:bytes");
    const wsNode = await waitForText(doc, "ws-state", "echo:hello");
    const sseNode = await waitForText(doc, "sse-state", "message:ready:sse-1");

    assert.ok(fetchNode, "expected fetch-state node");
    assert.ok(fetchJsonNode, "expected fetch-json-state node");
    assert.ok(fetchBytesNode, "expected fetch-bytes-state node");
    assert.ok(wsNode, "expected ws-state node");
    assert.ok(sseNode, "expected sse-state node");

    assert.equal(fetchNode.textContent, "200:fetch-ok:POST:ping");
    assert.equal(fetchJsonNode.textContent, "json:true");
    assert.equal(fetchBytesNode.textContent, "5:bytes");
    assert.equal(wsNode.textContent, "echo:hello");
    assert.equal(sseNode.textContent, "message:ready:sse-1");

    if (typeof instance.exports.nimui_unmount === "function") {
      instance.exports.nimui_unmount();
      assert.equal(host.listeners.size, 0, "all listeners should be detached after net unmount");
      assert.equal(host.wsSockets.size, 0, "all websocket handles should be closed after net unmount");
      assert.equal(host.sseStreams.size, 0, "all eventsource handles should be closed after net unmount");
    }
  } finally {
    netEnv.restore();
    env.restore();
  }
}

async function runFailSoftScenario(wasmPath) {
  const env = installFakeBrowserGlobals("/");
  try {
    const doc = buildFixtureDocument();
    const runtimeErrors = [];

    const { host } = await loadNimUiWasm(wasmPath, {
      selector: "#app",
      documentRef: doc,
      onRuntimeError: (err) => runtimeErrors.push(err),
      autoUnmountOnFatal: true
    });

    await tick();

    assert.equal(runtimeErrors.length, 1, "runtime error callback should fire exactly once");
    assert.equal(runtimeErrors[0]?.op, "nimui_start");
    assert.ok(host.getFatalError(), "host should retain fatal error details");
    assert.equal(host.listeners.size, 0, "listeners should be detached after auto-unmount on fatal");
  } finally {
    env.restore();
  }
}

async function main() {
  const wasmPath = process.argv[2];
  const scenario = process.argv[3] ?? "counter";

  if (!wasmPath) {
    throw new Error("usage: node dom_shim_runner.mjs <path-to-wasm> [counter|todo|router|controlled|net|failsoft]");
  }

  if (scenario === "counter") {
    await runCounterScenario(wasmPath);
  } else if (scenario === "todo") {
    await runTodoScenario(wasmPath);
  } else if (scenario === "router") {
    await runRouterScenario(wasmPath);
  } else if (scenario === "controlled") {
    await runControlledInputScenario(wasmPath);
  } else if (scenario === "net") {
    await runNetScenario(wasmPath);
  } else if (scenario === "failsoft") {
    await runFailSoftScenario(wasmPath);
  } else {
    throw new Error(`unknown scenario '${scenario}'`);
  }

  console.log(`PASS: wasm integration runner (${scenario})`);
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
