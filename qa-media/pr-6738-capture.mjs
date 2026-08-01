/* eslint-disable no-console -- standalone QA capture script; stdout IS the evidence transcript. */
import fs from "node:fs";
import { chromium } from "playwright";

const APEX = "rmarescu-1434-upi-autopay-subscr.apps.staging.gumroad.org";
const ROOT = `https://${APEX}:8443`;
const OUT = "/tmp/pw6738/final";
const rows = [];
const log = [];
const P = (...a) => {
  const s = a.join(" ");
  console.log(s);
  log.push(s);
};

const LEGS = [
  { tag: "inr-membership", slug: "qaupi", label: "INR membership (PR shape)", expectUpi: null },
  {
    tag: "inr-onetime-control",
    slug: "qaupione",
    label: "INR one-time (pre-existing lane, control)",
    expectUpi: true,
  },
];

function serverProps(page) {
  return page.evaluate(() => {
    const raw = document.documentElement.innerHTML.replace(/&quot;/gu, '"');
    const i = raw.indexOf('"checkout_payment"');
    if (i < 0) return null;
    const seg = raw.slice(i, i + 900);
    const pick = (k) => {
      const m = seg.match(new RegExp(`"${k}":(\\[[^\\]]*\\]|"[^"]*"|true|false|null|\\d+)`, "u"));
      return m ? m[1] : null;
    };
    return {
      integration: JSON.parse(pick("integration")),
      fallback_reason: JSON.parse(pick("fallback_reason")),
      currency: JSON.parse(pick("currency") || "null"),
      presentment_amount_cents: pick("presentment_amount_cents"),
      payment_method_types: pick("payment_method_types"),
    };
  });
}

async function paymentMenuText(page) {
  const frameText = [];
  for (const f of page.frames()) {
    if (!/js\.stripe\.com/u.test(f.url())) continue;
    try {
      frameText.push(await f.evaluate(() => (document.body ? document.body.innerText : "")));
    } catch {
      /* frame detached mid-read */
    }
  }
  const pageText = await page.evaluate(() => document.body.innerText || "");
  return { menu: frameText.join("\n"), page: pageText };
}

(async () => {
  const browser = await chromium.launch({
    args: [
      "--ignore-certificate-errors",
      `--host-resolver-rules=MAP ${APEX} 127.0.0.1:8443, MAP seller.${APEX} 127.0.0.1:8443, MAP *.${APEX} 127.0.0.1:8443`,
    ],
  });
  for (const leg of LEGS) {
    for (const [vp, dims] of [
      ["desktop", { width: 1440, height: 1200 }],
      ["mobile", { width: 375, height: 900 }],
    ]) {
      const ctx = await browser.newContext({
        ignoreHTTPSErrors: true,
        viewport: dims,
        deviceScaleFactor: 2,
        isMobile: vp === "mobile",
        hasTouch: vp === "mobile",
      });
      const page = await ctx.newPage();
      let errs = 0;
      page.on("pageerror", () => {
        errs++;
      });
      await page.goto(`${ROOT}/checkout?product=${leg.slug}&quantity=1`, {
        waitUntil: "domcontentloaded",
        timeout: 120000,
      });
      await page.waitForTimeout(18000);

      const props = await serverProps(page);
      if (!props) throw new Error(`ABORT ${leg.tag} ${vp}: no checkout_payment props`);
      if (props.payment_method_types === null)
        throw new Error(`ABORT ${leg.tag} ${vp}: server did not choose client-confirm`);

      // Bring the "Pay with" block into the viewport (mobile stacks it far down the page).
      try {
        await page.locator('text="Pay with"').first().scrollIntoViewIfNeeded({ timeout: 10000 });
      } catch (e) {
        P(`     (scroll: ${e.message.slice(0, 50)})`);
      }
      await page.waitForTimeout(4000);

      const { menu, page: pageText } = await paymentMenuText(page);
      const upiVisible = /\bUPI\b/iu.test(menu) || /\bUPI\b/u.test(pageText);
      const paypalVisible = /PayPal/iu.test(pageText);
      const total = (pageText.match(/Total\s*\n?\s*((?:US\$|₹|\$)\s?[\d,]+(?:\.\d{2})?)/u) || [])[1] || null;

      if (leg.expectUpi === true && !upiVisible) {
        throw new Error(`ABORT control ${vp}: UPI missing. menu=${menu.replace(/\n/gu, " | ").slice(0, 300)}`);
      }
      // The whole point: the membership leg must be reported honestly either way.
      P(`LEG ${leg.tag} ${vp} pageerrors=${errs} total=${total}`);
      P(`     server_props: ${JSON.stringify(props)}`);
      P(`     rendered: upi_visible=${upiVisible} paypal_visible=${paypalVisible}`);

      const file = `${OUT}/pr-6738-${leg.tag}-${vp}.png`;
      await page.screenshot({ path: file });
      rows.push({
        leg: leg.label,
        vp,
        ...props,
        upiVisible,
        paypalVisible,
        total,
        file: file.split("/").pop(),
      });
      await ctx.close();
    }
  }
  await browser.close();
  fs.writeFileSync(`${OUT}/rows.json`, JSON.stringify(rows, null, 1));
  fs.writeFileSync(`${OUT}/run.log`, log.join("\n"));
  P("ALL-LEGS-CAPTURED");
})().catch((e) => {
  console.log("RUN-FAILED", e.message);
  process.exit(1);
});
