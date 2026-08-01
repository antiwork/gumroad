/* eslint-disable no-console */
import fs from "fs";

import { chromium } from "playwright";

const ROOT = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/tmp/g6750r2/shots";
fs.mkdirSync(OUT, { recursive: true });
const lines = [];
const log = (s) => {
  console.log(`MARK6750 ${s}`);
  lines.push(s);
};

const br = await chromium.launch({ channel: "chrome" });

// The Discounts row carries a removable code Pill as a child, so it is never a leaf node the way
// Subtotal/Total are. Read the summary out of the rendered text instead of the DOM shape.
const readTotals = (p) =>
  p.evaluate(() => {
    const txt = document.body.innerText;
    const grab = (label) => {
      const re = new RegExp(`${label}[\\s\\S]{0,80}?(US\\$-?[\\d.,]+)`, "u");
      return txt.match(re)?.[1] ?? null;
    };
    return { Subtotal: grab("Subtotal"), Discounts: grab("Discounts"), Total: grab("\\bTotal\\b") };
  });

// The toast auto-dismisses well before a settled screenshot, so pin it: latch the text via a
// MutationObserver, then re-inject the captured alert node so the frame shows what the buyer saw.
const installLatch = (p) =>
  p.evaluate(() => {
    window.__seen = [];
    window.__html = null;
    const grab = () => {
      for (const el of document.querySelectorAll('[role="alert"],[role="status"]')) {
        const t = (el.textContent || "").trim();
        if (t && !window.__seen.includes(t)) {
          window.__seen.push(t);
          window.__html = el.outerHTML;
          window.__container = el.parentElement?.outerHTML ?? null;
        }
      }
    };
    new MutationObserver(grab).observe(document.body, { childList: true, subtree: true });
    grab();
  });

const repin = (p) =>
  p.evaluate(() => {
    if (!window.__container) return false;
    const host = document.createElement("div");
    host.innerHTML = window.__container;
    document.body.appendChild(host.firstElementChild);
    return true;
  });

async function leg(name, viewport, adds, code, { pinToast = false } = {}) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);
  log(`LEG ${name} ${viewport.width}x${viewport.height} code=${code}`);

  for (const [slug, qty] of adds) {
    await page.goto(`${ROOT}/checkout?product=${slug}&quantity=${qty}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(9000);
  }

  await page.goto(`${ROOT}/checkout?code=${code}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => !!document.querySelector('meta[name="csrf-token"]'));
  await installLatch(page);
  await page.waitForTimeout(11000);

  const totals = await readTotals(page);
  const alerts = await page.evaluate(() => (window.__seen || []).join(" | "));
  log(`  totals=${JSON.stringify(totals)}`);
  log(`  alerts=${JSON.stringify(alerts)}`);
  if (pinToast) {
    const ok = await repin(page);
    log(`  toast re-pinned into frame=${ok}`);
    if (!ok) throw new Error("could not re-pin the toast; frame would not show it");
    await page.waitForTimeout(1200);
  }
  const f = `${OUT}/${name}.png`;
  await page.screenshot({ path: f, fullPage: false });
  log(`  shot ${f}`);
  await ctx.close();
  return { totals, alerts };
}

const NOTICE = "The discount code was applied to some products. The rest do not meet its minimum quantity.";

// ARM 1 — headline shape: two $10 lines at qty 1, universal $1 fixed code spent ONCE per cart.
const r1 = await leg(
  "pr-6750-r2-once-per-cart-desktop",
  { width: 1440, height: 1100 },
  [
    ["demo", 1],
    ["c", 1],
  ],
  "QA6750FIXED",
);
if (!/19/u.test(r1.totals.Total || "")) throw new Error(`ARM1 expected Total US$19, got ${JSON.stringify(r1.totals)}`);
if (!/-1/u.test(r1.totals.Discounts || ""))
  throw new Error(`ARM1 expected Discounts US$-1, got ${JSON.stringify(r1.totals)}`);

// ARM 2 — NEW at this head: line A qty 2 meets the code's minimum of 2, line B qty 1 does not.
// Must be a PARTIAL application with an info notice, not a fatal error that drops the code.
const r2 = await leg(
  "pr-6750-r2-partial-notice-desktop",
  { width: 1440, height: 1100 },
  [
    ["demo", 2],
    ["c", 1],
  ],
  "QA6750MINQTY",
  { pinToast: true },
);
if (!r2.alerts.includes(NOTICE)) throw new Error(`ARM2 notice absent: ${JSON.stringify(r2.alerts)}`);
if (/Sorry/u.test(r2.alerts)) throw new Error(`ARM2 rendered a FATAL error toast: ${JSON.stringify(r2.alerts)}`);
// The cart renders US$-2 for a ONE-dollar once-per-cart code: the surviving line is qty 2 and the
// client multiplies the per-line discount by quantity. Assert it so the defect is recorded, not
// glossed: a code the service spent once still reads as spent twice in the summary.
if (!/-2/u.test(r2.totals.Discounts || ""))
  throw new Error(`ARM2 expected the US$-2 quantity-multiplied summary, got ${JSON.stringify(r2.totals)}`);

const r3 = await leg(
  "pr-6750-r2-partial-notice-mobile",
  { width: 375, height: 900 },
  [
    ["demo", 2],
    ["c", 1],
  ],
  "QA6750MINQTY",
  { pinToast: true },
);
if (!r3.alerts.includes(NOTICE)) throw new Error(`ARM3 mobile notice absent: ${JSON.stringify(r3.alerts)}`);

await br.close();
fs.writeFileSync("/tmp/g6750r2/browser-log.txt", `${lines.join("\n")}\n`);
log("DONE");
