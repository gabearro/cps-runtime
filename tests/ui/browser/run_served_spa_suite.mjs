import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");

const host = process.env.CPS_UI_HOST ?? "127.0.0.1";
const port = Number(process.env.CPS_UI_PORT ?? "9080");
const baseUrl = `http://${host}:${port}`;
const serverBin = process.env.CPS_UI_SERVER_BIN ?? path.join(repoRoot, "examples/ui/test_spa_server");

function httpGet(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => {
        body += chunk;
      });
      res.on("end", () => {
        resolve({ status: res.statusCode ?? 0, body });
      });
    });
    req.on("error", reject);
  });
}

async function waitForHealth(timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const res = await httpGet(`${baseUrl}/api/health`);
      if (res.status === 200 && res.body.trim() === "ok") {
        return;
      }
      lastError = new Error(`health returned ${res.status} (${res.body.trim()})`);
    } catch (err) {
      lastError = err;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`CPS UI server failed health check at ${baseUrl}/api/health: ${lastError?.message ?? "unknown error"}`);
}

function startServer() {
  if (!fs.existsSync(serverBin)) {
    throw new Error(`Server binary not found: ${serverBin}. Build it with: nim c -d:release -o:examples/ui/test_spa_server examples/ui/test_spa_server.nim`);
  }

  const child = spawn(serverBin, [], {
    cwd: repoRoot,
    env: {
      ...process.env,
      CPS_UI_HOST: host,
      CPS_UI_PORT: String(port)
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  child.stdout.on("data", (chunk) => process.stdout.write(`[cps-server] ${chunk}`));
  child.stderr.on("data", (chunk) => process.stderr.write(`[cps-server] ${chunk}`));
  return child;
}

async function stopServer(child) {
  if (!child || child.exitCode !== null) {
    return;
  }

  child.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
      resolve();
    }, 3000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
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

async function click(page, selector) {
  await page.locator(selector).click({ force: true });
}

async function runServedSpaTest(browserType) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`${baseUrl}/ui/test_spa.html`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("[data-testid='spa-title']");

    const tailwindState = await page.evaluate(() => {
      const hasTailwindSheet = Array.from(document.styleSheets).some((sheet) =>
        (sheet.href || "").includes("test_spa.tailwind.css")
      );
      const panel = document.querySelector(".surface-panel");
      const style = panel ? getComputedStyle(panel) : null;
      return {
        hasTailwindSheet,
        radius: style?.borderRadius ?? "0px",
        bg: style?.backgroundColor ?? ""
      };
    });
    assert.equal(tailwindState.hasTailwindSheet, true, "Tailwind stylesheet should be loaded");
    assert.notEqual(tailwindState.radius, "0px", "Tailwind component styles should apply");

    await expectContains(page, "[data-testid='dashboard-section']", "Hello Gabriel");
    await page.fill("[data-testid='name-input']", "Nim DSL");
    await expectContains(page, "[data-testid='welcome']", "Hello Nim DSL");
    await expectContains(page, "[data-testid='modal-status']", "name:Nim DSL");

    await click(page, "[data-testid='inc-button']");
    await expectContains(page, "[data-testid='dashboard-section']", "Count");
    await expectContains(page, "[data-testid='dashboard-section']", "1");

    await click(page, "[data-testid='capture-button']");
    await expectText(page, "[data-testid='capture-stats']", "capture=1, bubble=1");

    await click(page, "[data-testid='nav-tasks']");
    await expectContains(page, "[data-testid='tasks-section']", "Tasks");
    let tasks = await page.$$eval("[data-testid='task-list'] li", (nodes) => nodes.map((n) => n.textContent));
    assert.deepEqual(tasks, ["code", "test", "deploy"]);

    await click(page, "[data-testid='toggle-order']");
    tasks = await page.$$eval("[data-testid='task-list'] li", (nodes) => nodes.map((n) => n.textContent));
    assert.deepEqual(tasks, ["deploy", "test", "code"]);

    await click(page, "[data-testid='nav-labs']");
    await expectContains(page, "[data-testid='labs-section']", "Custom element works");
    await page.waitForSelector("[data-testid='custom-card']", { state: "attached" });
    await page.waitForSelector("[data-testid='sparkline']", { state: "attached" });
    await page.waitForSelector("[data-testid='math-sample']", { state: "attached" });
    await expectContains(page, "[data-testid='modal-status']", "view:labs");
  } finally {
    await browser.close();
  }
}

async function main() {
  const server = startServer();
  try {
    await waitForHealth();

    const targets = [
      ["chromium", chromium],
      ["firefox", firefox],
      ["webkit", webkit]
    ];

    for (const [name, browserType] of targets) {
      console.log(`Running served SPA integration on ${name}...`);
      await runServedSpaTest(browserType);
      console.log(`PASS: served SPA integration (${name})`);
    }
  } finally {
    await stopServer(server);
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
