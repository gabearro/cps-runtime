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
const port = Number(process.env.CPS_UI_PORT ?? "9081");
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
  throw new Error(`CPS UI server failed health check: ${lastError?.message ?? "unknown error"}`);
}

function startServer() {
  if (!fs.existsSync(serverBin)) {
    throw new Error(`Server binary not found: ${serverBin}. Build with nim c -d:release -o:examples/ui/test_spa_server examples/ui/test_spa_server.nim`);
  }

  const child = spawn(serverBin, [], {
    cwd: repoRoot,
    env: {
      ...process.env,
      CPS_UI_HOST: host,
      CPS_UI_PORT: String(port),
      CPS_UI_INDEX: "workspace.html"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  child.stdout.on("data", (chunk) => process.stdout.write(`[cps-server] ${chunk}`));
  child.stderr.on("data", (chunk) => process.stderr.write(`[cps-server] ${chunk}`));
  return child;
}

async function stopServer(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null) child.kill("SIGKILL");
      resolve();
    }, 3000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
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
  const ok = await page.evaluate((sel) => {
    const node = document.querySelector(sel);
    if (!node) return false;
    node.click();
    return true;
  }, selector);
  assert.equal(ok, true, `missing click target: ${selector}`);
}

async function clickTaskRow(page, expectedFragment) {
  const ok = await page.evaluate((fragment) => {
    const rows = Array.from(document.querySelectorAll("[data-testid='task-list'] li"));
    const row = rows.find((node) => (node.textContent || "").includes(fragment));
    if (!row) return false;
    row.click();
    return true;
  }, expectedFragment);
  assert.equal(ok, true, `missing task row containing: ${expectedFragment}`);
}

async function setFieldValue(page, selector, value, eventName = "input") {
  const ok = await page.evaluate(({ selector, value, eventName }) => {
    const node = document.querySelector(selector);
    if (!node) return false;
    node.value = value;
    node.dispatchEvent(new Event(eventName, { bubbles: true }));
    return true;
  }, { selector, value, eventName });
  assert.equal(ok, true, `missing editable field: ${selector}`);
}

async function runWorkspaceScenario(browserType) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`${baseUrl}/ui/workspace.html`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("[data-testid='app-title']");

    const tailwindState = await page.evaluate(() => {
      const hasSheet = Array.from(document.styleSheets).some((sheet) =>
        (sheet.href || "").includes("workspace.tailwind.css")
      );
      const frame = document.querySelector(".workspace-frame");
      const style = frame ? getComputedStyle(frame) : null;
      return {
        hasSheet,
        radius: style?.borderRadius ?? "0px",
        bg: style?.backgroundColor ?? ""
      };
    });
    if (!tailwindState.hasSheet && tailwindState.radius === "0px" && tailwindState.bg === "rgba(0, 0, 0, 0)") {
      console.warn(`[workspace-style] stylesheet signal missing on ${browserType.name()}; continuing functional assertions`);
    }

    await setFieldValue(page, "[data-testid='quick-input']", "Plan roadmap review");
    await click(page, "[data-testid='quick-add-btn']");

    await click(page, "a[href='/tasks']");
    await page.waitForSelector("[data-testid='nav-tasks']");
    await expectContains(page, "body", "Task Board");

    const taskTexts = await page.$$eval("[data-testid='task-list'] li", (nodes) => nodes.map((n) => n.textContent || ""));
    assert.equal(
      taskTexts.some((t) => t.includes("Plan roadmap review")),
      true,
      "quick-added task should appear on the board"
    );

    await clickTaskRow(page, "Plan roadmap review");
    await page.waitForSelector("[data-testid='task-modal']");
    await setFieldValue(page, "[data-testid='task-notes']", "Documented through Playwright");
    await click(page, "[data-testid='modal-close']");
    await page.waitForSelector("[data-testid='task-modal']", { state: "detached" });

    await click(page, "a[href='/focus']");
    await page.waitForSelector("[data-testid='nav-focus']");
    await page.waitForSelector("[data-testid='focus-queue']");
    await page.evaluate(() => {
      const queue = document.querySelector("[data-testid='focus-queue']");
      queue?.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
      queue?.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
    });
    await expectContains(page, "[data-testid='focus-queue']", "Energy: 2");

    await click(page, "a[href='/settings']");
    await page.waitForSelector("[data-testid='nav-settings']");
    await setFieldValue(page, "[data-testid='owner-input']", "Playwright Operator");
    await expectContains(page, "header", "Playwright Operator");

    await setFieldValue(page, "[data-testid='theme-select']", "ocean", "change");
    await expectContains(page, "header", "ocean");

    await setFieldValue(page, "[data-testid='goal-formula']", "30+15");
    await page.waitForSelector("[data-testid='goal-preview']");

    await click(page, "a[href='/insights/weekly?range=7d']");
    await page.waitForSelector("[data-testid='nav-insights']");
    await expectContains(page, "body", "Insights");
    assert.equal(page.url().includes("/insights/weekly"), true, "router should navigate to insights path");

    await click(page, "a[href='/']");
    await page.waitForSelector("[data-testid='nav-dashboard']");
    await page.evaluate(() => {
      const map = document.querySelector("[data-testid='dashboard-map']");
      map?.dispatchEvent(
        new PointerEvent("pointermove", {
          bubbles: true,
          clientX: 64,
          clientY: 22,
          pointerType: "mouse"
        })
      );
    });
    await page.waitForFunction(() => {
      const map = document.querySelector("[data-testid='dashboard-map']");
      return map && map.textContent.includes("@");
    });

    await page.evaluate(() => {
      const root = document.querySelector("[tabindex='0']");
      root?.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true }));
    });
    await page.waitForSelector("[data-testid='command-palette']");
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
      console.log(`Running workspace SPA integration on ${name}...`);
      await runWorkspaceScenario(browserType);
      console.log(`PASS: workspace SPA integration (${name})`);
    }
  } finally {
    await stopServer(server);
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
