/* eslint-disable no-console */
// PR 6750 r3 capture: the cross-sell cart shape the body documents as broken
// (Total US$50, discount gone) at the re-armed head b578fa5c1. Asserts the
// discount SURVIVES now, which is the opposite of what the previous frames show.
import fs from "fs";
import { chromium } from "playwright";

const ROOT = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/tmp/pw6750/shots";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log(`MARK6750R3B ${s}`);

const br = await chromium.launch({ channel: "chrome" });

function readTotals(page) {
  return page.evaluate(() => {
    const out = {};
    for (const el of document.querySelectorAll("*")) {
      const t = (el.textContent || "").trim();
      if (el.children.length === 0 && /^(Subtotal|Discounts|Total)$/u.test(t)) {
        out[t] = ((el.closest("div,li,tr") || el.parentElement)?.textContent || "").replace(t, "").trim();
      }
    }
    out.__body = document.body.innerText;
    return out;
  });
}

async function leg(name, viewport) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);

  // Cart order matters: the checkout page renders newest-first, so adding X last
  // puts it FIRST in the hash the service iterates — the order that lost the
  // discount before b578fa5c1.
  for (const slug of ["demo", "c", "of"]) {
    await page.goto(`${ROOT}/checkout?product=${slug}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(4000);
  }
  await page.goto(`${ROOT}/checkout?code=QA6750FIXED`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(7000);

  // The floating reCAPTCHA badge sits over the Total row at 375px, so the value
  // is unreadable in the frame. Hiding it changes nothing the PR touches.
  await page.addStyleTag({ content: ".grecaptcha-badge{display:none !important}" });
  await page.waitForTimeout(500);

  const t = readTotals(page);
  const totals = await t;
  log(`${name} Subtotal=${JSON.stringify(totals.Subtotal)} Total=${JSON.stringify(totals.Total)}`);

  const body = totals.__body;
  const lines = ["QA6750 Widget A", "QA6750 Widget B", "QA6750 Widget X"].filter((n) => body.includes(n));
  log(`${name} cart_lines=${JSON.stringify(lines)}`);
  if (lines.length !== 3) throw new Error(`${name}: expected 3 cart lines, got ${JSON.stringify(lines)}`);

  // The Discounts row's chip splits the text node, so read the amount off innerText.
  const discRow = (body.match(/Discounts[\s\S]{0,80}/u) || [""])[0].replace(/\n+/gu, " ");
  log(`${name} discounts_row=${JSON.stringify(discRow)}`);

  if (!/US\$50\b/u.test(totals.Subtotal || "")) throw new Error(`${name}: subtotal not US$50: ${totals.Subtotal}`);
  // The whole point: the discount survives the cross-sell pass now.
  if (!/US\$49\b/u.test(totals.Total || ""))
    throw new Error(`${name}: ABORT total is not US$49 (pre-fix was US$50): ${totals.Total}`);
  if (!/QA6750FIXED/u.test(discRow)) throw new Error(`${name}: discount chip missing`);
  if (!/-1\b/u.test(discRow.replace(/US\$/gu, ""))) throw new Error(`${name}: discount is not -1: ${discRow}`);

  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: false });
  log(`${name} shot OK`);
  await ctx.close();
}

await leg("pr-6750-r3-crosssell-discount-kept-desktop", { width: 1280, height: 1000 });
await leg("pr-6750-r3-crosssell-discount-kept-mobile", { width: 375, height: 900 });

await br.close();
log("DONE");
