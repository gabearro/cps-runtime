import { chromium } from "playwright";

const targetUrl = process.env.CPS_HTTP3_INTEROP_URL || "";
const expectedProtocol = (process.env.CPS_HTTP3_EXPECTED_PROTOCOL || "h3").toLowerCase();
const liveMode = (() => {
  const raw = (process.env.CPS_HTTP3_LIVE_MODE || "").toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes";
})();
const liveGetPath = process.env.CPS_HTTP3_LIVE_GET_PATH || "/live-get";
const livePostPath = process.env.CPS_HTTP3_LIVE_POST_PATH || "/live-post";
const livePostBody = process.env.CPS_HTTP3_LIVE_POST_BODY || "browser-live-post";
const expectedGetBody = process.env.CPS_HTTP3_LIVE_EXPECT_GET_BODY || "";
const expectedPostBody = process.env.CPS_HTTP3_LIVE_EXPECT_POST_BODY || "";
const allowInsecureCerts = (() => {
  const raw = (process.env.CPS_HTTP3_ALLOW_INSECURE_CERTS || "").toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes";
})();
const ignoreCertSpki = process.env.CPS_HTTP3_IGNORE_CERT_SPKI || "";
const runningInCi = (() => {
  const ci = (process.env.CI || "").toLowerCase();
  return ci === "1" || ci === "true" || (process.env.GITHUB_ACTIONS || "").toLowerCase() === "true";
})();
const requireTarget = (() => {
  const raw = (process.env.CPS_HTTP3_REQUIRE_TARGET || "").toLowerCase();
  if (raw === "1" || raw === "true" || raw === "yes") {
    return true;
  }
  if (raw === "0" || raw === "false" || raw === "no") {
    return false;
  }
  return runningInCi;
})();
const requireWebTransport = (() => {
  const raw = (process.env.CPS_HTTP3_REQUIRE_WEBTRANSPORT || "").toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes";
})();

async function main() {
  const launchArgs = [
    "--enable-quic",
    "--enable-experimental-web-platform-features",
    "--enable-features=WebTransport",
  ];
  if (targetUrl.length > 0) {
    const u = new URL(targetUrl);
    const port = u.port || (u.protocol === "https:" ? "443" : "80");
    launchArgs.push(`--origin-to-force-quic-on=${u.hostname}:${port}`);
  }
  if (allowInsecureCerts) {
    launchArgs.push("--ignore-certificate-errors");
    launchArgs.push("--allow-insecure-localhost");
  }
  if (ignoreCertSpki.length > 0) {
    launchArgs.push(`--ignore-certificate-errors-spki-list=${ignoreCertSpki}`);
  }

  const browser = await chromium.launch({
    headless: true,
    args: launchArgs,
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();

  if (targetUrl.length > 0) {
    const cdp = await context.newCDPSession(page);
    await cdp.send("Network.enable");
    let negotiatedProtocol = "";
    cdp.on("Network.responseReceived", (evt) => {
      if (!negotiatedProtocol && evt?.response?.url?.startsWith(targetUrl)) {
        negotiatedProtocol = (evt.response.protocol || "").toLowerCase();
      }
    });

    const resp = await page.goto(targetUrl, { waitUntil: "domcontentloaded", timeout: 30_000 });
    if (!resp) {
      throw new Error(`No response for URL: ${targetUrl}`);
    }
    if (!negotiatedProtocol) {
      throw new Error(`Unable to capture negotiated protocol for URL: ${targetUrl}`);
    }
    if (negotiatedProtocol !== expectedProtocol) {
      throw new Error(`Expected protocol ${expectedProtocol}, got ${negotiatedProtocol}`);
    }
    console.log(`PASS: Browser negotiated ${negotiatedProtocol} for ${targetUrl}`);

    if (liveMode) {
      const baseUrl = new URL(targetUrl).origin;
      let live = null;
      let lastLiveErr = null;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          live = await page.evaluate(async ({ baseUrl, getPath, postPath, postBody }) => {
            const getResp = await fetch(new URL(getPath, baseUrl), { method: "GET" });
            const getText = await getResp.text();
            const postResp = await fetch(new URL(postPath, baseUrl), {
              method: "POST",
              headers: { "content-type": "text/plain" },
              body: postBody,
            });
            const postText = await postResp.text();
            return {
              getStatus: getResp.status,
              getBody: getText,
              postStatus: postResp.status,
              postBody: postText,
            };
          }, {
            baseUrl,
            getPath: liveGetPath,
            postPath: livePostPath,
            postBody: livePostBody,
          });
          lastLiveErr = null;
          break;
        } catch (err) {
          lastLiveErr = err;
          if (attempt < 3) {
            await page.waitForTimeout(200);
          }
        }
      }
      if (lastLiveErr) {
        throw lastLiveErr;
      }

      if (live.getStatus !== 200) {
        throw new Error(`Expected live GET status 200, got ${live.getStatus}`);
      }
      if (live.postStatus !== 200) {
        throw new Error(`Expected live POST status 200, got ${live.postStatus}`);
      }
      if (expectedGetBody.length > 0 && live.getBody !== expectedGetBody) {
        throw new Error(`Expected live GET body '${expectedGetBody}', got '${live.getBody}'`);
      }
      if (expectedPostBody.length > 0 && live.postBody !== expectedPostBody) {
        throw new Error(`Expected live POST body '${expectedPostBody}', got '${live.postBody}'`);
      }
      console.log(`LIVE_GET_STATUS:${live.getStatus}`);
      console.log(`LIVE_GET_BODY:${live.getBody}`);
      console.log(`LIVE_POST_STATUS:${live.postStatus}`);
      console.log(`LIVE_POST_BODY:${live.postBody}`);
      console.log("PASS: Browser live HTTP/3 fetch GET/POST checks");
    }
  } else {
    if (requireTarget) {
      throw new Error("CPS_HTTP3_INTEROP_URL is required but not set");
    }
    console.log("WARN: CPS_HTTP3_INTEROP_URL not set; protocol negotiation check skipped");
    await page.goto("https://example.com", { waitUntil: "domcontentloaded", timeout: 30_000 });
  }

  const primitives = await page.evaluate(() => ({
    hasFetch: typeof fetch === "function",
    hasWebTransport: typeof WebTransport === "function",
    hasReadableStream: typeof ReadableStream === "function",
    isSecureContext,
  }));
  if (!primitives.hasFetch || !primitives.hasReadableStream) {
    throw new Error("Browser missing required fetch/stream primitives");
  }
  console.log("PASS: Browser exposes fetch/stream primitives");
  if (!primitives.isSecureContext) {
    throw new Error("Browser page is not a secure context for WebTransport checks");
  }
  if (primitives.hasWebTransport) {
    console.log("PASS: Browser exposes WebTransport constructor");
  } else {
    if (requireWebTransport) {
      throw new Error("Browser does not expose WebTransport constructor");
    }
    console.log("WARN: Browser does not expose WebTransport constructor");
  }

  await browser.close();
}

main().catch((err) => {
  console.error(err.stack || String(err));
  process.exit(1);
});
