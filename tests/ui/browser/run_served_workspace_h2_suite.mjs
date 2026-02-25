import assert from "node:assert/strict";
import fs from "node:fs";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");

const host = process.env.CPS_UI_HOST ?? "127.0.0.1";
const port = Number(process.env.CPS_UI_PORT ?? "9085");
const baseUrl = `https://${host}:${port}`;
const serverBin = process.env.CPS_UI_SERVER_BIN ?? path.join(repoRoot, "examples/ui/workspace_demo_server");

const certDir = path.join(os.tmpdir(), "cps-ui-browser-h2");
const certFile = path.join(certDir, "workspace_h2_cert.pem");
const keyFile = path.join(certDir, "workspace_h2_key.pem");
const insecureAgent = new https.Agent({ rejectUnauthorized: false });

function isH2Protocol(protocol) {
  const p = String(protocol ?? "").toLowerCase();
  return p === "h2" || p.includes("http/2");
}

function ensureSelfSignedCert() {
  if (fs.existsSync(certFile) && fs.existsSync(keyFile)) {
    return;
  }
  fs.mkdirSync(certDir, { recursive: true });
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-keyout",
      keyFile,
      "-out",
      certFile,
      "-days",
      "7",
      "-nodes",
      "-subj",
      "/CN=localhost"
    ],
    { stdio: "ignore" }
  );
}

function httpsGet(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { agent: insecureAgent }, (res) => {
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
      const res = await httpsGet(`${baseUrl}/api/health`);
      if (res.status === 200 && res.body.trim() === "ok") {
        return;
      }
      lastError = new Error(`health returned ${res.status} (${res.body.trim()})`);
    } catch (err) {
      lastError = err;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`workspace h2 server failed health check at ${baseUrl}/api/health: ${lastError?.message ?? "unknown error"}`);
}

function startServer() {
  if (!fs.existsSync(serverBin)) {
    throw new Error(
      `Server binary not found: ${serverBin}. Build with nim c -d:release -o:examples/ui/workspace_demo_server examples/ui/workspace_demo_server.nim`
    );
  }

  const child = spawn(serverBin, [], {
    cwd: repoRoot,
    env: {
      ...process.env,
      CPS_UI_HOST: host,
      CPS_UI_PORT: String(port),
      CPS_UI_USE_TLS: "1",
      CPS_UI_ENABLE_HTTP2: "1",
      CPS_UI_TLS_CERT: certFile,
      CPS_UI_TLS_KEY: keyFile
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  child.stdout.on("data", (chunk) => process.stdout.write(`[workspace-h2-server] ${chunk}`));
  child.stderr.on("data", (chunk) => process.stderr.write(`[workspace-h2-server] ${chunk}`));
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

async function runWorkspaceH2BrowserTest() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  const responses = [];
  await cdp.send("Network.enable");
  cdp.on("Network.responseReceived", (event) => {
    responses.push({
      url: event.response.url,
      type: event.type,
      protocol: String(event.response.protocol ?? "")
    });
  });

  try {
    await page.goto(`${baseUrl}/workspace/ssr`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("[data-testid='app-title']");
    await page.waitForSelector("[data-testid='nav-dashboard']");
    await page.locator("a[href='/tasks']").click();
    await page.waitForSelector("[data-testid='nav-tasks']");
    await page.waitForSelector("[data-testid='task-list']");
    assert.equal(page.url().includes("/tasks"), true, "expected router to navigate to /tasks");

    const docOverH2 = responses.some(
      (r) => r.url.includes("/workspace/ssr") && isH2Protocol(r.protocol)
    );
    const wasmOverH2 = responses.some(
      (r) => r.url.includes("/ui/workspace_app.wasm") && isH2Protocol(r.protocol)
    );

    assert.equal(docOverH2, true, "expected /workspace/ssr document to be served over HTTP/2");
    assert.equal(wasmOverH2, true, "expected workspace wasm asset to be served over HTTP/2");
  } finally {
    await browser.close();
  }
}

async function main() {
  ensureSelfSignedCert();
  const server = startServer();
  try {
    await waitForHealth();
    console.log("Running workspace HTTPS + HTTP/2 browser integration on chromium...");
    await runWorkspaceH2BrowserTest();
    console.log("PASS: workspace HTTPS + HTTP/2 browser integration (chromium)");
  } finally {
    await stopServer(server);
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || String(err));
  process.exit(1);
});
