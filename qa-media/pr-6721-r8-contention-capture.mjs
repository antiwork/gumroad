import fs from "fs";
import { chromium } from "playwright";

// PR #6721 re-QA at head ea5492aba — live-first precedence on BOTH fetch_leniently branches.
// Overlay values are read off the live response; no expectation is hardcoded into a frame.
//
// SHARED PREVIEW DB: a concurrent sibling session owns products 1 and 3 and renames them
// mid-run, so this leg deliberately contends products 4 (live holder) and 2 (mapped target).
const ROOT = "https://gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const RUN = "r126656";
const OUT = "/tmp/qa6721/shots2";
fs.mkdirSync(OUT, { recursive: true });

const LIVE_NAME = "Beautiful music-and-sound-design widget"; // product 4, seller gumbomusic
const MAPPED_NAME = "Beautiful membership"; // product 2, seller seller@gumroad.com — the mapping target

const legs = [
  {
    name: "bare-domain-live-first",
    url: `${ROOT}/l/xcontend-${RUN}`,
    note:
      "BARE DOMAIN. A legacy_permalinks row maps this slug to product 2 (seller@gumroad.com,\n" +
      '"Beautiful membership"); product 4 (gumbomusic) holds it LIVE. Live must win — pre-fix,\n' +
      "the unscoped branch read the mapping FIRST and served the other seller's product.",
    mustShow: LIVE_NAME,
    mustNotShow: MAPPED_NAME,
  },
];

const views = [
  { name: "desktop", width: 1440, height: 1000 },
  { name: "mobile375", width: 375, height: 812 },
];

const log = [];
const browser = await chromium.launch();

for (const v of views) {
  for (const leg of legs) {
    const ctx = await browser.newContext({
      viewport: { width: v.width, height: v.height },
      deviceScaleFactor: 2,
      ignoreHTTPSErrors: true,
    });
    const page = await ctx.newPage();
    const resp = await page.goto(leg.url, { waitUntil: "domcontentloaded", timeout: 120000 });
    await page.waitForTimeout(3000);
    const status = resp.status();
    const finalUrl = page.url();
    const info = await page.evaluate(() => {
      const h1 = document.querySelector("h1");
      return {
        title: (h1 && h1.innerText.trim()) || document.title,
        text: document.body.innerText,
        broke: /Page not found|Something broke|404/iu.test(document.body.innerText.slice(0, 400)),
      };
    });
    const line = `${v.name.padEnd(9)} ${leg.name} ${leg.url} -> HTTP ${status} final=${finalUrl} product="${info.title}" broke=${info.broke}`;
    process.stdout.write(`${line}\n`);
    log.push(line);
    if (status !== 200 || info.broke) throw new Error(`ABORT ${line}`);
    if (!info.text.includes(leg.mustShow)) throw new Error(`ABORT live product not rendered: ${line}`);
    if (info.text.includes(leg.mustNotShow)) throw new Error(`ABORT mapped product served over live: ${line}`);

    await page.evaluate(
      ({ req, st, fin, prod, note }) => {
        const d = document.createElement("div");
        d.style.cssText =
          "position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;" +
          "font:12px/1.45 ui-monospace,Menlo,monospace;padding:8px 10px;white-space:pre-wrap;" +
          "border-bottom:2px solid #0f0";
        d.textContent =
          `[harness overlay — values read from the live response]\n` +
          `requested   ${req}\nHTTP        ${st}\nfinal URL   ${fin}\nserved      ${prod}\n${note}`;
        document.body.prepend(d);
        window.scrollTo(0, 0);
      },
      { req: leg.url, st: status, fin: finalUrl, prod: info.title, note: leg.note },
    );
    await page.waitForTimeout(500);
    await page.screenshot({ path: `${OUT}/pr-6721-${v.name}-${leg.name}.png`, fullPage: false });
    await ctx.close();
  }
}

await browser.close();
fs.writeFileSync("/tmp/qa6721/capture2-log.txt", `${log.join("\n")}\n`);
process.stdout.write("DONE\n");
