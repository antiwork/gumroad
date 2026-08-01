/* eslint-disable no-console */
import fs from "fs";
import { chromium } from "playwright";

const ROOT = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/Users/gumclaw/qa/pr6750x";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log(`MARK6750B ${s}`);

// The Discounts row carries a removable code Pill as a child, so it is never a leaf node the
// way Subtotal/Total are. Read the summary out of the rendered text instead of the DOM shape.
const readTotals = (p) =>
  p.evaluate(() => {
    const txt = document.body.innerText;
    const grab = (label) => {
      const re = new RegExp(`${label}[\\s\\S]{0,80}?(US\\$-?[\\d.,]+)`, "u");
      return txt.match(re)?.[1] ?? null;
    };
    return { Subtotal: grab("Subtotal"), Discounts: grab("Discounts"), Total: grab("\\bTotal\\b") };
  });

const br = await chromium.launch();

async function leg(name, viewport, code) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);

  // Seed the cart one line at a time, then apply the code via the URL: the in-cart discount
  // form is gated on a seller-scoped has_offer_codes flag that a UNIVERSAL code leaves false.
  for (const slug of ["demo", "c"]) {
    await page.goto(`${ROOT}/checkout?product=${slug}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3500);
  }
  await page.goto(`${ROOT}/checkout?code=${code}`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(6000);

  const totals = await readTotals(page);
  log(`${name} totals=${JSON.stringify(totals)}`);

  const body = await page.evaluate(() => document.body.innerText);
  const hasX = body.includes("Widget X");
  log(`${name} cross_sell_rendered=${hasX}`);
  // Every money string on the page, so the body can quote what the buyer sees.
  log(`${name} money=${JSON.stringify([...body.matchAll(/US\$-?[\d.,]+/gu)].map((x) => x[0]))}`);

  if (!/Sorry/u.test(body)) log(`${name} no fatal error toast`);
  else throw new Error(`${name}: fatal error toast on page`);

  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: viewport.width < 500 });
  await ctx.close();
  return totals;
}

await leg("pr-6750-x-crosssell-desktop", { width: 1280, height: 1000 }, "QA6750FIXED");
await leg("pr-6750-x-crosssell-mobile", { width: 375, height: 812 }, "QA6750FIXED");

await br.close();
log("DONE");
