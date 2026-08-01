// Capture what the bare domain serves when another seller holds a mapped slug live.
import fs from "fs";
import { chromium } from "playwright";

const ROOT = "https://gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const HOST = "gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const SLUG = "xseller-old-974496";
const OUT = "/tmp/g6721r8";
fs.mkdirSync(OUT, { recursive: true });

// The live claimant's product, and the mapped product it must NOT be served over.
const CLAIMANT_NAME = "Beautiful films widget";
const MAPPED_NAME = "Beautiful widget";

const legs = [
  {
    name: "bare-domain",
    url: `${ROOT}/l/${SLUG}`,
    mustShow: CLAIMANT_NAME,
    mustNotShow: MAPPED_NAME,
    finalIncludes: "gumbofilm.",
  },
  {
    name: "claimant-own-subdomain",
    url: `https://gumbofilm.${HOST}/l/${SLUG}`,
    mustShow: CLAIMANT_NAME,
    mustNotShow: MAPPED_NAME,
    finalIncludes: "gumbofilm.",
  },
  {
    name: "mapping-owner-new-slug",
    url: `https://seller.${HOST}/l/xseller-new-974496`,
    mustShow: MAPPED_NAME,
    mustNotShow: CLAIMANT_NAME,
    finalIncludes: "seller.",
  },
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
    text: document.body.innerText,
    len: document.body.innerText.length,
  }));
  // A blank body means the pod recycled mid-run; the frame would be evidence of nothing.
  if (info.len < 100) throw new Error(`blank page (len=${info.len}) - pod recycle, retry`);
  // Without these a wrong result still renders a plausible frame: the overlay would
  // faithfully print a 404, or the mapped product served over the live claimant.
  if (status !== 200) throw new Error(`ABORT ${leg.name}: HTTP ${status}`);
  if (!finalUrl.includes(leg.finalIncludes)) {
    throw new Error(`ABORT ${leg.name}: landed on ${finalUrl}, expected host ${leg.finalIncludes}`);
  }
  if (!info.text.includes(leg.mustShow)) {
    throw new Error(`ABORT ${leg.name}: "${leg.mustShow}" not rendered (h1="${info.h1}")`);
  }
  if (info.text.includes(leg.mustNotShow)) {
    throw new Error(`ABORT ${leg.name}: "${leg.mustNotShow}" served instead`);
  }

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
