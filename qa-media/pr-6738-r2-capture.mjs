/* eslint-disable no-console */
import fs from "fs";
import { chromium } from "playwright";

const APEX = "rmarescu-1434-upi-autopay-subscr.apps.staging.gumroad.org";
const ROOT = `https://${APEX}`;
const OUT = "/tmp/g6738r2/shots";
fs.mkdirSync(OUT, { recursive: true });
const log = [];
const say = (s) => {
  console.log(s);
  log.push(s);
};

const browser = await chromium.launch({
  args: [
    "--ignore-certificate-errors",
    `--host-resolver-rules=MAP ${APEX} 127.0.0.1:8443, MAP seller.${APEX} 127.0.0.1:8443, MAP *.${APEX} 127.0.0.1:8443`,
  ],
});

const propsOf = (page) =>
  page.evaluate(() => {
    const p = JSON.parse(document.querySelector("[data-page]").getAttribute("data-page"));
    const cp = p?.props?.checkout_payment ?? p?.props?.checkout?.checkout_payment ?? null;
    const eo = cp?.elements_options ?? {};
    return {
      integration: cp?.integration ?? null,
      recurring_upi_registration: cp?.recurring_upi_registration ?? null,
      fallback_reason: cp?.fallback_reason ?? null,
      currency: eo.currency ?? null,
      presentment_amount_cents: eo.presentment_amount_cents ?? null,
      listed_currency_display: eo.listed_currency_display ?? null,
      types: eo.payment_method_types ?? null,
    };
  });

async function stripeText(page) {
  let t = "";
  for (const f of page.frames()) {
    if (!/js\.stripe\.com/u.test(f.url())) continue;
    try {
      t += await f.evaluate(() => (document.body ? document.body.innerText : ""));
    } catch {
      /* detached */
    }
  }
  return t;
}

async function rowY(page, re) {
  for (const f of page.frames()) {
    if (!/js\.stripe\.com/u.test(f.url())) continue;
    let off = null;
    try {
      off = await f.evaluate((src) => {
        const rx = new RegExp(src, "u");
        const n = Array.from(document.querySelectorAll("*")).find(
          (e) => e.children.length === 0 && rx.test((e.textContent || "").trim()),
        );
        return n ? n.getBoundingClientRect().top : null;
      }, re);
    } catch {
      continue;
    }
    if (off === null) continue;
    const fe = await f.frameElement();
    const b = await fe.boundingBox();
    return (b ? b.y : 0) + off;
  }
  return null;
}

const legs = [
  { permalink: "qaupi", desc: "membership-upi", label: "THIS PR: INR Autopay membership, flags on, Indian buyer" },
  { permalink: "qaupione", desc: "onetime-control", label: "CONTROL: INR one-time, same seller / flags / IP" },
];
const views = [
  { name: "desktop", width: 1440, height: 1100 },
  { name: "mobile", width: 375, height: 812 },
];

for (const leg of legs) {
  for (const v of views) {
    const ctx = await browser.newContext({
      viewport: { width: v.width, height: v.height },
      deviceScaleFactor: 2,
      isMobile: v.name === "mobile",
      hasTouch: v.name === "mobile",
    });
    const page = await ctx.newPage();
    await page.goto(`${ROOT}/checkout?product=${leg.permalink}&quantity=1`, {
      waitUntil: "domcontentloaded",
      timeout: 120000,
    });
    await page.waitForTimeout(9000);
    const props = await propsOf(page);
    const st = await stripeText(page);
    const total = await page.evaluate(() => {
      const m = document.body.innerText.match(/Total\s*\n?\s*([^\n]+)/u);
      return m ? m[1].trim() : null;
    });
    const upiVisible = /\bUPI\b/iu.test(st);
    const inrElement = props.currency === "inr";
    const inrTotal = total ? /₹/u.test(total) : false;
    say(`LEG ${leg.desc}/${v.name} props=${JSON.stringify(props)}`);
    say(
      `LEG ${leg.desc}/${v.name} total=${JSON.stringify(total)} upi_in_element=${upiVisible} element_inr=${inrElement} total_inr=${inrTotal} MISMATCH=${inrElement && !inrTotal}`,
    );

    let y = await rowY(page, "^UPI$");
    for (let i = 0; i < 8 && y !== null && !(y > 100 && y < v.height - 200); i++) {
      await page.evaluate((d) => window.scrollBy(0, d), y - 400);
      await page.waitForTimeout(2200);
      y = await rowY(page, "^UPI$");
    }
    say(`LEG ${leg.desc}/${v.name} upi_row_y=${y}`);
    const file = `${OUT}/pr-6738-${leg.desc}-${v.name}.png`;
    await page.screenshot({ path: file });
    say(`SHOT ${file}`);
    // also a top-of-cart shot proving the total
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(1500);
    const f2 = `${OUT}/pr-6738-${leg.desc}-${v.name}-cart.png`;
    await page.screenshot({ path: f2 });
    say(`SHOT ${f2}`);
    await ctx.close();
  }
}
await browser.close();
fs.writeFileSync(`${OUT}/results.txt`, `${log.join("\n")}\n`);
say("DONE");
