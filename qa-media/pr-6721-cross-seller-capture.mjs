// Cross-seller contention capture for gumroad#6721 / gumroad-private#1653.
// The claim is made by pr-6721-cross-seller-claim.rb; this proves what the BARE
// domain actually serves to a visitor once a different seller holds the slug live.
import fs from "fs";
import { chromium } from "playwright";

const ROOT = "https://gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const HOST = "gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const SLUG = "xseller-old-974496";
const OUT = "/tmp/g6721r8";
fs.mkdirSync(OUT, { recursive: true });

const legs = [
  { name: "bare-domain", url: `${ROOT}/l/${SLUG}` },
  { name: "claimant-own-subdomain", url: `https://gumbofilm.${HOST}/l/${SLUG}` },
  { name: "mapping-owner-new-slug", url: `https://seller.${HOST}/l/xseller-new-974496` },
];

const log = [];
const browser = await chromium.launch();

for (const leg of legs) {
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  page.setDefaultTimeout(45000);
  const resp = await page.goto(leg.url, { waitUntil: "domcontentloaded" });
  const status = resp.status();
  await page.waitForTimeout(3000);
  const finalUrl = page.url();
  const info = await page.evaluate(() => ({
    h1: (document.querySelector("h1") || {}).innerText || document.title,
    len: document.body.innerText.length,
  }));
  // A blank body means the pod recycled mid-run; the frame would be evidence of nothing.
  if (info.len < 100) throw new Error(`blank page (len=${info.len}) - pod recycle, retry`);

  await page.evaluate(
    ({ url, httpStatus, landedOn }) => {
      const d = document.createElement("div");
      d.style.cssText =
        "position:fixed;top:0;left:0;right:0;z-index:99999;background:#111;color:#0f0;" +
        "font:12px/1.5 ui-monospace,monospace;padding:6px 10px;white-space:pre-wrap";
      d.textContent =
        `[harness overlay - values read from the live response]\nrequested: ${url}\n` +
        `HTTP ${httpStatus}   final: ${landedOn}`;
      document.body.prepend(d);
      window.scrollTo(0, 0);
    },
    { url: leg.url, httpStatus: status, landedOn: finalUrl },
  );
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${OUT}/pr-6721-cross-seller-${leg.name}.png` });
  log.push(`${leg.name}: ${leg.url} -> HTTP ${status} final=${finalUrl} h1="${info.h1}"`);
  await ctx.close();
}

await browser.close();
fs.writeFileSync(`${OUT}/log.txt`, `${log.join("\n")}\n`);
