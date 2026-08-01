/* eslint-disable no-console */
import fs from "fs";
import { chromium } from "playwright";

const ROOT = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/Users/gumclaw/qa/pr6750x";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log(`MARK6750D ${s}`);

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

async function leg(name, viewport) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);

  // Cart: A + B, then apply the fixed code via the URL (the in-cart form is gated on a
  // seller-scoped has_offer_codes flag that a UNIVERSAL code leaves false).
  for (const slug of ["demo", "c"]) {
    await page.goto(`${ROOT}/checkout?product=${slug}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3500);
  }
  await page.goto(`${ROOT}/checkout?code=QA6750FIXED`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(6000);

  const before = await readTotals(page);
  log(`${name} BEFORE (A+B, code applied) ${JSON.stringify(before)}`);

  // Now ADD the cross-sell (the third product, `of`, $30) to the same cart. Its
  // products_data entry is the one this commit zeroes.
  await page.goto(`${ROOT}/checkout?product=of`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(6000);

  const after = await readTotals(page);
  log(`${name} AFTER (cross-sell added) ${JSON.stringify(after)}`);

  const body = await page.evaluate(() => document.body.innerText);
  if (!body.includes("Widget X")) throw new Error(`${name}: cross-sell not in cart`);
  if (/Sorry/u.test(body)) throw new Error(`${name}: fatal error toast on page`);
  log(`${name} cart_lines=${["Widget A", "Widget B", "Widget X"].filter((n) => body.includes(n)).join(",")}`);

  // Scroll the order summary into frame.
  await page.evaluate(() => {
    const el = [...document.querySelectorAll("*")].find(
      (e) => e.children.length === 0 && /^Subtotal$/u.test((e.textContent || "").trim()),
    );
    if (el) window.scrollTo(0, window.scrollY + el.getBoundingClientRect().top - 140);
  });
  await page.waitForTimeout(1200);

  await page.screenshot({ path: `${OUT}/${name}.png` });
  await ctx.close();
  return after;
}

await leg("pr-6750-x-crosssell-added-desktop", { width: 1280, height: 900 });
await leg("pr-6750-x-crosssell-added-mobile", { width: 375, height: 812 });

await br.close();
log("DONE");
