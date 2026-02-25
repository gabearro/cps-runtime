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
const port = Number(process.env.CPS_UI_PORT ?? "9082");
const baseUrl = `http://${host}:${port}`;
const serverBin = process.env.CPS_UI_SERVER_BIN ?? path.join(repoRoot, "examples/ui/net_demo_server");

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
  throw new Error(`Network demo server failed health check at ${baseUrl}/api/health: ${lastError?.message ?? "unknown error"}`);
}

function startServer() {
  if (!fs.existsSync(serverBin)) {
    throw new Error(`Server binary not found: ${serverBin}. Build it with: nim c -d:release -o:examples/ui/net_demo_server examples/ui/net_demo_server.nim`);
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

  child.stdout.on("data", (chunk) => process.stdout.write(`[net-server] ${chunk}`));
  child.stderr.on("data", (chunk) => process.stderr.write(`[net-server] ${chunk}`));
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

async function runServedNetTest(browserType) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(`${baseUrl}/ui/net_demo.html`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("[data-testid='net-app']");

    await expectText(page, "[data-testid='fetch-state']", "200:fetch-ok:POST:ping");
    await expectText(page, "[data-testid='ws-state']", "echo:hello");
    await expectText(page, "[data-testid='sse-state']", "message:ready:sse-1");

    const routesNote = await page.textContent(".legend");
    assert.equal(routesNote.includes("/api/net/fetch"), true, "legend should mention API route");
    assert.equal(routesNote.includes("/ws/net"), true, "legend should mention WS route");
    assert.equal(routesNote.includes("/events/net"), true, "legend should mention SSE route");
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
      console.log(`Running served network demo integration on ${name}...`);
      await runServedNetTest(browserType);
      console.log(`PASS: served network demo integration (${name})`);
    }
  } finally {
    await stopServer(server);
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
