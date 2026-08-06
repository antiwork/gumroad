/* eslint-disable no-console -- standalone QA capture script; stdout IS the evidence transcript. */
import fs from "fs";
import { chromium } from "playwright";

const APEX = "rmarescu-1434-upi-autopay-subscr.apps.staging.gumroad.org";
const ROOT = `https://${APEX}`;
const OUT = "/tmp/g6738/shots2";
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
    const cp = p?.props?.checkout?.checkout_payment ?? null;
    const eo = cp?.elements_options ?? {};
    return {
      integration: cp?.integration ?? null,
      recurring_upi_registration: cp?.recurring_upi_registration ?? null,
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
    } catch {}
  }
  return t;
}

const legs = [
  {
    permalink: "qaupi",
    desc: "membership-upi-mounted",
    label: "THIS PR's shape: INR Autopay membership, flag on, Indian buyer",
  },
  { permalink: "qaupione", desc: "onetime-control", label: "CONTROL: INR one-time, same seller / flags / IP" },
];
const views = [
  { name: "desktop", width: 1440, height: 1100 },
  { name: "mobile", width: 375, height: 812 },
];

const results = {};

for (const v of views) {
  for (const leg of legs) {
    const ctx = await browser.newContext({
      viewport: { width: v.width, height: v.height },
      deviceScaleFactor: 2,
      ignoreHTTPSErrors: true,
    });
    const page = await ctx.newPage();
    await page.goto(`${ROOT}/checkout?product=${leg.permalink}&quantity=1`, {
      waitUntil: "domcontentloaded",
      timeout: 120000,
    });
    await page.waitForTimeout(11000);

    const props = await propsOf(page);
    const stext = await stripeText(page);
    const upi = /\bUPI\b/iu.test(stext);
    const bodyText = await page.evaluate(() => document.body.innerText);
    const total = (bodyText.match(/Total\s*\n\s*(\S+)/u) || [])[1] ?? null;
    const subtotal = (bodyText.match(/Subtotal\s*\n\s*(\S+)/u) || [])[1] ?? null;

    // the element is mounted in INR; is the summary showing INR too?
    const elementInr = props.currency === "inr" && props.presentment_amount_cents === 49900;
    const summaryInr = /₹/u.test(total ?? "");
    const mismatch = elementInr && !summaryInr;

    const key = `${v.name}/${leg.desc}`;
    results[key] = { props, upi, subtotal, total, elementInr, summaryInr, mismatch };
    say(
      `${v.name.padEnd(8)} ${leg.desc.padEnd(24)} UPI=${upi} recurring_upi_registration=${props.recurring_upi_registration} element=${props.currency}/${props.presentment_amount_cents} summaryTotal=${total} MISMATCH=${mismatch}`,
    );

    if (!upi) throw new Error(`ABORT ${key}: UPI not mounted`);

    await page.evaluate(
      ({ label, types, cur, amt, upi, total, subtotal, rur, mismatch }) => {
        const d = document.createElement("div");
        d.style.cssText = `position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;font:12px/1.45 ui-monospace,Menlo,monospace;padding:8px 10px;white-space:pre-wrap;border-bottom:2px solid ${
          mismatch ? "#f33" : "#0f0"
        }`;
        d.textContent =
          `${label}\n` +
          `server props   payment_method_types=${types}  recurring_upi_registration=${rur}\n` +
          `Payment Element mounted in  currency=${cur}  presentment_amount_cents=${amt}  (= ₹499.00)\n` +
          `rendered       UPI row = ${upi ? "YES" : "NO"}     cart Subtotal = ${subtotal}   Total = ${total}${
            mismatch ? `\n⛔ MISMATCH: element charges ₹499.00, summary shows ${total}` : `  ✓ consistent`
          }`;
        document.body.prepend(d);
      },
      {
        label: leg.label,
        types: JSON.stringify(props.types),
        cur: props.currency,
        amt: props.presentment_amount_cents,
        upi,
        total,
        subtotal,
        rur: props.recurring_upi_registration,
        mismatch,
      },
    );
    await page.waitForTimeout(500);
    await page.screenshot({ path: `${OUT}/pr-6738-${leg.desc}-${v.name}.png` });
    await ctx.close();
  }
}

await browser.close();
fs.writeFileSync("/tmp/g6738/browser-results2.json", JSON.stringify(results, null, 2));
fs.writeFileSync("/tmp/g6738/browser-log2.txt", `${log.join("\n")}\n`);
say(
  results["desktop/onetime-control"].mismatch === false
    ? "CONTROL consistent (₹) => the membership mismatch is shape-specific, not a fixture artifact"
    : "ABORT: control also mismatched => fixture problem",
);
say("DONE");
