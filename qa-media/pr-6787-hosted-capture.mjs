/* eslint-disable no-console */
// PR 6787: the custom product landing page's new rating / review-count markers,
// shot on the HOSTED preview app rather than a local rails runner render — the
// existing frames in the body came from an offline harness, so nothing has yet
// proved the surface renders through the real controller + iframe sandbox.
import fs from "fs";
import { chromium } from "playwright";

const HOST = "feat-gp1673-custom-page-review-f.apps.staging.gumroad.org";
const STORE = `https://seller.${HOST}`;
const OUT = "/tmp/pw6787/shots";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log(`MARK6787C ${s}`);

const ARMS = [
  { slug: "demo", name: "shown", expectRating: "4.5", expectCount: "4" },
  { slug: "membershipdemo", name: "hidden", expectRating: null, expectCount: null },
  { slug: "hg", name: "noreviews", expectRating: null, expectCount: null },
];

const br = await chromium.launch({ channel: "chrome" });

// The interpolated page is served into a sandboxed iframe by the product page.
// Read the marker elements from the IFRAME's document, not the parent's.
async function readMarkers(page) {
  for (let i = 0; i < 20; i++) {
    for (const f of page.frames()) {
      const got = await f
        .evaluate(() => {
          const g = (k) => {
            const el = document.querySelector(`[data-gumroad-field="${k}"]`);
            return el ? (el.textContent || "").trim() : null;
          };
          if (!document.querySelector("[data-gumroad-field]")) return null;
          return {
            rating: g("rating"),
            count: g("review-count"),
            arm: (document.getElementById("arm") || {}).textContent,
          };
        })
        .catch(() => null);
      if (got) return got;
    }
    await page.waitForTimeout(1500);
  }
  return null;
}

async function leg(arm, viewport, suffix) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);

  const url = `${STORE}/l/${arm.slug}`;
  const resp = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 120000 });
  log(`${arm.name}${suffix} status=${resp && resp.status()} url=${page.url()}`);
  await page.waitForTimeout(7000);

  const m = await readMarkers(page);
  if (!m) throw new Error(`${arm.name}: no [data-gumroad-field] element found in any frame`);
  log(`${arm.name}${suffix} arm_label=${JSON.stringify((m.arm || "").trim())}`);
  log(`${arm.name}${suffix} rating=${JSON.stringify(m.rating)} count=${JSON.stringify(m.count)}`);

  if (arm.expectRating) {
    if (m.rating !== arm.expectRating) throw new Error(`${arm.name}: rating ${m.rating} != ${arm.expectRating}`);
    if (m.count !== arm.expectCount) throw new Error(`${arm.name}: count ${m.count} != ${arm.expectCount}`);
  } else {
    // Nothing written: the author's own copy must survive, and no rating may leak.
    if (m.rating !== "Be the first to review") throw new Error(`${arm.name}: fallback lost, rating=${m.rating}`);
    if (m.count !== "no") throw new Error(`${arm.name}: count fallback lost, count=${m.count}`);
    if (/^\d/u.test(m.rating || "")) throw new Error(`${arm.name}: a rating leaked: ${m.rating}`);
  }

  const png = `${OUT}/pr-6787-hosted-${arm.name}${suffix}.png`;
  await page.screenshot({ path: png });
  log(`${arm.name}${suffix} shot ${png}`);
  await ctx.close();
  return m;
}

for (const arm of ARMS) await leg(arm, { width: 1280, height: 900 }, "-desktop");
await leg(ARMS[0], { width: 375, height: 812 }, "-mobile");
await leg(ARMS[1], { width: 375, height: 812 }, "-mobile");

await br.close();
log("DONE");
