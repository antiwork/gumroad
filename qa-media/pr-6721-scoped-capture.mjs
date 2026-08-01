import fs from "fs";
import { chromium } from "playwright";

// Verify seller-scoped redirects when another seller still holds the released slug.
// The global legacy table cannot represent this collision without displacing its existing mapping.
const ROOT = "gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const SLUG_OLD = "zshared-r6721b";
const SLUG_NEW = "zmoved-r6721b";
const OUT = "/tmp/qa6721scoped";
fs.mkdirSync(OUT, { recursive: true });

const RENAMER = "Beautiful education widget";
const CLAIMANT = "Beautiful software-development widget";

const legs = [
  {
    name: "renamer-host-retired-slug",
    url: `https://gumboeducation.${ROOT}/l/${SLUG_OLD}`,
    note:
      "THE FIX. gumboeducation renamed off this slug while gumbosoftware still holds it live.\n" +
      "legacy_permalinks could not record it (globally unique, and the slug is contended), so\n" +
      "pre-fix this shared link 404'd. The seller-scoped redirect now serves their own product.",
    mustShow: RENAMER,
    mustNotShow: CLAIMANT,
  },
  {
    name: "renamer-host-current-slug",
    url: `https://gumboeducation.${ROOT}/l/${SLUG_NEW}`,
    note: "CONTROL. The slug gumboeducation renamed TO still answers normally.",
    mustShow: RENAMER,
    mustNotShow: CLAIMANT,
  },
  {
    name: "claimant-host-live-slug",
    url: `https://gumbosoftware.${ROOT}/l/${SLUG_OLD}`,
    note:
      "NO LEAK. The same slug on the live holder's own host must still serve THEIR product —\n" +
      "a scoped redirect is keyed by seller_id and can never cross sellers.",
    mustShow: CLAIMANT,
    mustNotShow: RENAMER,
  },
  {
    name: "bare-domain-live-first",
    url: `https://${ROOT}/l/${SLUG_OLD}`,
    note:
      "BARE DOMAIN unchanged. The scoped table is consulted only on a seller-scoped host, so\n" +
      "gumroad.com/l/:slug still resolves live-first to the seller who holds the slug.",
    mustShow: CLAIMANT,
    mustNotShow: RENAMER,
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
    const line = `${v.name.padEnd(9)} ${leg.name.padEnd(26)} ${leg.url} -> HTTP ${status} final=${finalUrl} product="${info.title}" broke=${info.broke}`;
    process.stdout.write(`${line}\n`);
    log.push(line);
    if (status !== 200 || info.broke) throw new Error(`ABORT ${line}`);
    if (!info.text.includes(leg.mustShow)) throw new Error(`ABORT expected product not rendered: ${line}`);
    if (info.text.includes(leg.mustNotShow)) throw new Error(`ABORT wrong seller's product served: ${line}`);

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
    await page.screenshot({ path: `${OUT}/pr-6721-scoped-${v.name}-${leg.name}.png`, fullPage: false });
    await ctx.close();
  }
}

await browser.close();
fs.writeFileSync(`${OUT}/log.txt`, `${log.join("\n")}\n`);
process.stdout.write("DONE\n");
