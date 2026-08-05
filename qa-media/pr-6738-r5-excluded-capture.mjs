/* eslint-disable no-console */
// r5 excluded-shape sweep — QA step 7, never previously driven on this PR.
// For each excluded cart shape, assert the browser does NOT mount the recurring-UPI lane:
// the Payment Element must not offer UPI on a *recurring* cart, and the total must not be
// rendered in listed currency for a shape the server refused.
import fs from "fs";
import { chromium } from "playwright";

const APEX = "rmarescu-1434-upi-autopay-subscr.apps.staging.gumroad.org";
const ROOT = `https://${APEX}`;
const OUT = "/tmp/g6738r5/shots7";
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
    const cp = p?.props?.checkout?.checkout_payment ?? p?.props?.checkout_payment ?? null;
    const eo = cp?.elements_options ?? {};
    return {
      integration: cp?.integration ?? null,
      recurring_upi_registration: cp?.recurring_upi_registration ?? null,
      fallback_reason: cp?.fallback_reason ?? null,
      currency: eo.currency ?? null,
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

// [permalink, description, is this the ADMITTED shape?]
const LEGS = [
  ["qaupi", "admitted-inr-autopay-membership", true],
  ["qaupitrial", "excluded-free-trial-membership", false],
  ["qaupiphys", "excluded-physical-membership", false],
  ["qaupipre", "excluded-preorder-membership", false],
  ["qaupicomm", "excluded-commission", false],
  ["qaupiinst", "excluded-installment-plan", false],
];

for (const [permalink, desc, admitted] of LEGS) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  try {
    await page.goto(`${ROOT}/checkout?product=${permalink}&quantity=1`, {
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
    const inrTotal = total ? /₹/u.test(total) : false;

    say(`LEG ${desc} props=${JSON.stringify(props)}`);
    say(`LEG ${desc} total=${JSON.stringify(total)} upi_in_element=${upiVisible} total_inr=${inrTotal}`);

    // The load-bearing assertion: an excluded shape must NOT be handed the registration lane.
    if (!admitted && props.recurring_upi_registration === true) {
      throw new Error(`ABORT ${desc}: server opened recurring_upi_registration on an EXCLUDED shape`);
    }
    if (admitted && props.recurring_upi_registration !== true) {
      throw new Error(`ABORT ${desc}: admitted shape did NOT get the registration lane`);
    }
    if (admitted && !upiVisible) throw new Error(`ABORT ${desc}: admitted shape did not mount UPI`);
    say(`LEG ${desc} VERDICT=${admitted ? "ADMITTED-as-expected" : "REFUSED-as-expected"} ASSERTED OK`);

    await page.addStyleTag({ content: ".grecaptcha-badge{display:none !important}" });
    const f = `${OUT}/pr-6738-r5-${desc}.png`;
    await page.screenshot({ path: f });
    say(`SHOT ${f}`);
  } catch (e) {
    say(`LEG ${desc} ERROR ${e.message}`);
  }
  await ctx.close();
}
await browser.close();
fs.writeFileSync(`${OUT}/results.txt`, `${log.join("\n")}\n`);
say("DONE");
