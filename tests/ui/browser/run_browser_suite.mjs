import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import { chromium, firefox, webkit } from "playwright";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");

const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "application/javascript; charset=utf-8"],
  [".mjs", "application/javascript; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".json", "application/json; charset=utf-8"],
  [".css", "text/css; charset=utf-8"]
]);

function startStaticServer(rootDir) {
  const server = http.createServer((req, res) => {
    const urlPath = new URL(req.url, "http://localhost").pathname;
    const rawPath = decodeURIComponent(urlPath);
    const normalized = path.normalize(rawPath).replace(/^\/+/, "");
    let fsPath = path.join(rootDir, normalized);

    if (rawPath === "/" || rawPath === "") {
      fsPath = path.join(rootDir, "tests/ui/browser/harness.html");
    }

    if (!fsPath.startsWith(rootDir)) {
      res.statusCode = 403;
      res.end("forbidden");
      return;
    }

    if (!fs.existsSync(fsPath) || fs.statSync(fsPath).isDirectory()) {
      res.statusCode = 404;
      res.end("not found");
      return;
    }

    const ext = path.extname(fsPath);
    res.setHeader("Content-Type", mimeTypes.get(ext) ?? "application/octet-stream");
    fs.createReadStream(fsPath).pipe(res);
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({
        server,
        baseUrl: `http://127.0.0.1:${addr.port}`
      });
    });
  });
}

async function loadScenario(page, baseUrl, wasmPath, options = {}) {
  await page.goto(`${baseUrl}/tests/ui/browser/harness.html`, { waitUntil: "domcontentloaded" });

  const result = await page.evaluate(async ({ wasmPath, options }) => {
    const mod = await import("/src/cps/ui/js/loader.js");
    const errors = [];
    const events = [];
    const app = await mod.loadNimUiWasm(wasmPath, {
      selector: "#app",
      mode: options.mode ?? "mount",
      onRuntimeError: (err) => {
        errors.push({
          op: err?.op ?? "",
          message: err?.message ?? "",
          nimError: err?.nimError ?? ""
        });
      },
      onRuntimeEvent: (eventPayload) => {
        events.push(String(eventPayload ?? ""));
      },
      autoUnmountOnFatal: options.autoUnmountOnFatal ?? true
    });

    window.__nimui = app;
    window.__nimuiErrors = errors;
    window.__nimuiEvents = events;

    return {
      errors,
      events,
      fatal: app.host?.getFatalError?.() ?? null
    };
  }, { wasmPath, options });

  return result;
}

async function unmount(page) {
  await page.evaluate(() => {
    if (window.__nimui?.instance?.exports?.nimui_unmount) {
      window.__nimui.instance.exports.nimui_unmount();
    }
  });
}

async function runCounterTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await loadScenario(page, baseUrl, "/tests/ui/out/counter_app.wasm");
    await page.waitForSelector("h1");
    await expectText(page, "h1", "Count: 0");

    await page.click("button");
    await expectText(page, "h1", "Count: 1");

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function runControlledInputTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await loadScenario(page, baseUrl, "/tests/ui/out/controlled_input_app.wasm");
    await page.waitForSelector("input");
    await expectText(page, "p", "hello|false");

    await page.fill("input", "nimui-browser");
    await expectText(page, "p", "nimui-browser|false");

    await page.evaluate(() => {
      const input = document.querySelector("input");
      input.checked = true;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await expectText(page, "p", "nimui-browser|true");

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function runRouterTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await loadScenario(page, baseUrl, "/tests/ui/out/router_app.wasm");
    await page.evaluate(() => {
      history.replaceState({}, "", "/");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    await expectContains(page, "#app", "Home");

    await page.click("a");
    await expectContains(page, "#app", "User:42");
    await expectContains(page, "#app", "Tab:profile");

    await page.goBack();
    await expectContains(page, "#app", "Home");

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function runRouterLinkModifierSemanticsTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  const selector = "a";

  const resetHome = async () => {
    await page.evaluate(() => {
      history.replaceState({}, "", "/");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    await expectPath(page, "/");
    await expectContains(page, "#app", "Home");
  };

  const triggerSyntheticClick = async (clickOpts = {}) =>
    page.evaluate(
      ({ sel, clickOpts }) => {
        const link = document.querySelector(sel);
        if (!link) {
          throw new Error("router link not found");
        }
        const ev = new MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          button: clickOpts.button ?? 0,
          ctrlKey: !!clickOpts.ctrlKey,
          metaKey: !!clickOpts.metaKey,
          shiftKey: !!clickOpts.shiftKey,
          altKey: !!clickOpts.altKey
        });
        link.dispatchEvent(ev);
        const preventedByHandler = ev.defaultPrevented;
        if (!preventedByHandler && typeof ev.preventDefault === "function") {
          ev.preventDefault();
        }
        return preventedByHandler;
      },
      { sel: selector, clickOpts }
    );

  try {
    await loadScenario(page, baseUrl, "/tests/ui/out/router_app.wasm");
    await resetHome();
    await page.waitForSelector(selector, { state: "attached" });
    await page.evaluate((sel) => {
      const link = document.querySelector(sel);
      if (!link) {
        throw new Error("router link not found");
      }
      link.setAttribute("href", "javascript:void(0)");
    }, selector);

    let prevented = await triggerSyntheticClick({ ctrlKey: true });
    assert.equal(prevented, false, "ctrl-click should not be SPA-intercepted");
    await resetHome();

    prevented = await triggerSyntheticClick({ metaKey: true });
    assert.equal(prevented, false, "meta-click should not be SPA-intercepted");
    await resetHome();

    prevented = await triggerSyntheticClick({ shiftKey: true });
    assert.equal(prevented, false, "shift-click should not be SPA-intercepted");
    await resetHome();

    prevented = await triggerSyntheticClick({ altKey: true });
    assert.equal(prevented, false, "alt-click should not be SPA-intercepted");
    await resetHome();

    prevented = await triggerSyntheticClick({ button: 1 });
    assert.equal(prevented, false, "middle-click should not be SPA-intercepted");
    await resetHome();

    await page.evaluate((sel) => {
      const link = document.querySelector(sel);
      if (!link) {
        throw new Error("router link not found");
      }
      link.setAttribute("target", "_blank");
      link.removeAttribute("download");
      link.removeAttribute("rel");
    }, selector);
    prevented = await triggerSyntheticClick({});
    assert.equal(prevented, false, "target=_blank should not be SPA-intercepted");
    await resetHome();

    await page.evaluate((sel) => {
      const link = document.querySelector(sel);
      if (!link) {
        throw new Error("router link not found");
      }
      link.removeAttribute("target");
      link.setAttribute("download", "artifact.txt");
      link.removeAttribute("rel");
    }, selector);
    prevented = await triggerSyntheticClick({});
    assert.equal(prevented, false, "download links should not be SPA-intercepted");
    await resetHome();

    await page.evaluate((sel) => {
      const link = document.querySelector(sel);
      if (!link) {
        throw new Error("router link not found");
      }
      link.removeAttribute("target");
      link.removeAttribute("download");
      link.setAttribute("rel", "external");
    }, selector);
    prevented = await triggerSyntheticClick({});
    assert.equal(prevented, false, "rel=external should not be SPA-intercepted");

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function runFailSoftTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    const result = await loadScenario(page, baseUrl, "/tests/ui/out/fail_soft_app.wasm", {
      autoUnmountOnFatal: true
    });

    assert.equal(result.errors.length, 1, "expected one runtime error callback");
    assert.equal(result.errors[0].op, "nimui_start");

    const listenerCount = await page.evaluate(() => window.__nimui?.host?.listeners?.size ?? -1);
    assert.equal(listenerCount, 0, "expected listeners detached after fail-soft auto-unmount");
  } finally {
    await browser.close();
  }
}

async function runHydrationMismatchDiagnosticsTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`${baseUrl}/tests/ui/browser/harness.html`, { waitUntil: "domcontentloaded" });
    await page.evaluate(() => {
      const root = document.querySelector("#app");
      if (!root) {
        throw new Error("missing #app root");
      }
      root.innerHTML = "<main><h1>Pre-rendered</h1><button>noop</button></main>";
    });

    const result = await loadScenario(page, baseUrl, "/tests/ui/out/counter_app.wasm", {
      mode: "hydrate"
    });

    await page.waitForSelector("h1");
    await expectText(page, "h1", "Count: 0");

    const hydrationEvents = result.events
      .map((entry) => {
        try {
          return JSON.parse(entry);
        } catch (_) {
          return null;
        }
      })
      .filter((entry) => entry?.type === "hydration-mismatch");
    assert.ok(hydrationEvents.length > 0, "expected hydration mismatch runtime event");

    const hydrationError = await page.evaluate(() => {
      const instance = window.__nimui?.instance;
      const exports = instance?.exports;
      if (!exports) {
        return "";
      }
      const lenFn = exports.nimui_last_hydration_error_len;
      const copyFn = exports.nimui_copy_last_hydration_error;
      const allocFn = exports.nimui_alloc;
      const deallocFn = exports.nimui_dealloc;
      const mem = exports.memory;
      if (
        typeof lenFn !== "function" ||
        typeof copyFn !== "function" ||
        typeof allocFn !== "function" ||
        typeof deallocFn !== "function" ||
        !mem?.buffer
      ) {
        return "";
      }

      const len = Number(lenFn()) >>> 0;
      if (len === 0) {
        return "";
      }
      const ptr = Number(allocFn(len + 1));
      try {
        const copied = Number(copyFn(ptr, len + 1)) >>> 0;
        if (copied === 0) {
          return "";
        }
        const bytes = new Uint8Array(mem.buffer, ptr, copied);
        return new TextDecoder().decode(bytes);
      } finally {
        deallocFn(ptr);
      }
    });
    assert.ok(
      hydrationError.includes("mismatch"),
      `expected exported hydration mismatch details, got: ${hydrationError}`
    );

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function runDslSpaTest(browserType, baseUrl) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await loadScenario(page, baseUrl, "/tests/ui/out/test_spa_app.wasm");

    await expectContains(page, "[data-testid='dashboard-section']", "Hello Gabriel");

    await page.fill("[data-testid='name-input']", "Nim DSL");
    await expectContains(page, "[data-testid='welcome']", "Hello Nim DSL");
    await expectContains(page, "[data-testid='modal-status']", "name:Nim DSL");

    await page.click("[data-testid='inc-button']");
    await expectContains(page, "[data-testid='dashboard-section']", "Count");
    await expectContains(page, "[data-testid='dashboard-section']", "1");

    await page.click("[data-testid='capture-button']");
    await expectText(page, "[data-testid='capture-stats']", "capture=1, bubble=1");

    await page.click("[data-testid='nav-tasks']");
    await expectContains(page, "[data-testid='tasks-section']", "Tasks");

    let tasks = await page.$$eval("[data-testid='task-list'] li", (nodes) =>
      nodes.map((n) => n.textContent)
    );
    assert.deepEqual(tasks, ["code", "test", "deploy"]);

    await page.click("[data-testid='toggle-order']");
    tasks = await page.$$eval("[data-testid='task-list'] li", (nodes) =>
      nodes.map((n) => n.textContent)
    );
    assert.deepEqual(tasks, ["deploy", "test", "code"]);

    await page.click("[data-testid='nav-labs']");
    await expectContains(page, "[data-testid='labs-section']", "Custom element works");
    await page.waitForSelector("[data-testid='custom-card']", { state: "attached" });
    await page.waitForSelector("[data-testid='sparkline']", { state: "attached" });
    await page.waitForSelector("[data-testid='math-sample']", { state: "attached" });
    await expectContains(page, "[data-testid='modal-status']", "view:labs");

    await unmount(page);
  } finally {
    await browser.close();
  }
}

async function expectText(page, selector, expected) {
  await page.waitForFunction(
    ({ selector, expected }) => {
      const node = document.querySelector(selector);
      return node && node.textContent === expected;
    },
    { selector, expected }
  );
}

async function expectContains(page, selector, expectedFragment) {
  await page.waitForFunction(
    ({ selector, expectedFragment }) => {
      const node = document.querySelector(selector);
      return node && node.textContent.includes(expectedFragment);
    },
    { selector, expectedFragment }
  );
}

async function expectPath(page, expectedPath) {
  await page.waitForFunction(
    ({ expectedPath }) => `${window.location.pathname}${window.location.search}` === expectedPath,
    { expectedPath }
  );
}

async function main() {
  const { server, baseUrl } = await startStaticServer(repoRoot);
  try {
    const targets = [
      ["chromium", chromium],
      ["firefox", firefox],
      ["webkit", webkit]
    ];

    for (const [name, browserType] of targets) {
      console.log(`Running browser suite on ${name}...`);
      await runCounterTest(browserType, baseUrl);
      await runControlledInputTest(browserType, baseUrl);
      await runRouterTest(browserType, baseUrl);
      await runRouterLinkModifierSemanticsTest(browserType, baseUrl);
      await runHydrationMismatchDiagnosticsTest(browserType, baseUrl);
      await runDslSpaTest(browserType, baseUrl);
      await runFailSoftTest(browserType, baseUrl);
      console.log(`PASS: browser suite (${name})`);
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
