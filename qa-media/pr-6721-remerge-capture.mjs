import fs from "fs";
import { chromium } from "playwright";

const HOST = "seller.gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const ROOT = "https://gp1619-legacy-permalink-on-renam.apps.staging.gumroad.org";
const RUN = "r779281";
const OUT = "/tmp/g6721/shots";
fs.mkdirSync(OUT, { recursive: true });

const legs = [
  { slug: `hop-a-${RUN}`, desc: "two-hops-back" },
  { slug: `hop-b-${RUN}`, desc: "one-hop-back" },
  { slug: `hop-c-${RUN}`, desc: "current-slug" },
];
const views = [
  { name: "desktop", width: 1440, height: 1000 },
  { name: "mobile375", width: 375, height: 812 },
];

const log = [];
const browser = await chromium.launch();

for (const v of views) {
  const ctx = await browser.newContext({
    viewport: { width: v.width, height: v.height },
    deviceScaleFactor: 2,
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  for (const leg of legs) {
    const url = `https://${HOST}/l/${leg.slug}`;
    const resp = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 120000 });
    await page.waitForTimeout(2500);
    const status = resp.status();
    const finalUrl = page.url();
    const finalSlug = finalUrl.split("/l/")[1]?.split(/[?#]/u)[0] ?? "(none)";
    const bodyText = await page.evaluate(() => document.body.innerText.slice(0, 300));
    const is404 = /Page not found|Something broke|404/iu.test(bodyText);
    const line = `${v.name.padEnd(9)} ${leg.desc.padEnd(14)}: /l/${leg.slug} -> HTTP ${status} final=${finalSlug} notfound=${is404}`;
    process.stdout.write(`${line}\n`);
    log.push(line);
    if (status !== 200 || is404) throw new Error(`ABORT unexpected: ${line}`);
    if (finalSlug !== `hop-c-${RUN}`) throw new Error(`ABORT wrong forward target: ${line}`);

    // overlay so each frame proves its own caption
    await page.evaluate(
      ({ req, st, fin }) => {
        const d = document.createElement("div");
        d.style.cssText =
          "position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;" +
          "font:13px/1.5 ui-monospace,Menlo,monospace;padding:8px 10px;white-space:pre-wrap;" +
          "border-bottom:2px solid #0f0";
        d.textContent = `requested  /l/${req}\nHTTP       ${st}\nfinal URL  ${fin}`;
        document.body.prepend(d);
      },
      { req: leg.slug, st: status, fin: finalUrl },
    );
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${OUT}/pr-6721-${v.name}-${leg.desc}.png`, fullPage: false });
  }
  await ctx.close();
}

// bare-domain control: root host must also forward
const ctx2 = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
  deviceScaleFactor: 2,
  ignoreHTTPSErrors: true,
});
const p2 = await ctx2.newPage();
const r2 = await p2.goto(`${ROOT}/l/hop-a-${RUN}`, { waitUntil: "domcontentloaded", timeout: 120000 });
await p2.waitForTimeout(2500);
const l2 = `bare      two-hops-back : ${ROOT}/l/hop-a-${RUN} -> HTTP ${r2.status()} final=${p2.url()}`;
process.stdout.write(`${l2}\n`);
log.push(l2);
if (r2.status() !== 200) throw new Error(`ABORT bare domain: ${l2}`);
await p2.evaluate(
  ({ req, st, fin }) => {
    const d = document.createElement("div");
    d.style.cssText =
      "position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;font:13px/1.5 ui-monospace,Menlo,monospace;padding:8px 10px;white-space:pre-wrap;border-bottom:2px solid #0f0";
    d.textContent = `requested  (bare domain) /l/${req}\nHTTP       ${st}\nfinal URL  ${fin}`;
    document.body.prepend(d);
  },
  { req: `hop-a-${RUN}`, st: r2.status(), fin: p2.url() },
);
await p2.waitForTimeout(400);
await p2.screenshot({ path: `${OUT}/pr-6721-bare-domain-two-hops-back.png` });
await ctx2.close();

await browser.close();
fs.writeFileSync("/tmp/g6721/capture-log.txt", `${log.join("\n")}\n`);
process.stdout.write("DONE\n");
