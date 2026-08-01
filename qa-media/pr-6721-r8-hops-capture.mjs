import fs from "fs";
import { chromium } from "playwright";

// Capture seller-host and bare-domain behavior across multiple renames.
const ROOT = "https://gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const HOST = "https://gumbowriting.gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const RUN = "r126656";
const LIVE_NAME = "Beautiful writing-and-publishing widget";
const OUT = "/tmp/qa6721/shots3";
fs.mkdirSync(OUT, { recursive: true });

const legs = [
  {
    name: "seller-two-hops-back",
    url: `${HOST}/l/yhop-a-${RUN}`,
    note: "seller subdomain — slug retired TWO renames ago",
  },
  {
    name: "seller-one-hop-back",
    url: `${HOST}/l/yhop-b-${RUN}`,
    note: "seller subdomain — slug retired ONE rename ago",
  },
  {
    name: "seller-current-slug",
    url: `${HOST}/l/yhop-c-${RUN}`,
    note: "seller subdomain — the current live slug (control)",
  },
  {
    name: "bare-two-hops-back",
    url: `${ROOT}/l/yhop-a-${RUN}`,
    note: "bare gumroad.com domain — same retired slug, no live product holds it",
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
    const line = `${v.name.padEnd(9)} ${leg.name.padEnd(20)} ${leg.url} -> HTTP ${status} final=${finalUrl} product="${info.title}" broke=${info.broke}`;
    process.stdout.write(`${line}\n`);
    log.push(line);
    if (status !== 200 || info.broke) throw new Error(`ABORT ${line}`);
    if (!info.text.includes(LIVE_NAME)) throw new Error(`ABORT wrong product served: ${line}`);
    if (!finalUrl.includes(`yhop-c-${RUN}`)) throw new Error(`ABORT did not land on the live slug: ${line}`);

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
fs.writeFileSync("/tmp/qa6721/capture3-log.txt", `${log.join("\n")}\n`);
process.stdout.write("DONE\n");
