/* eslint-disable no-console */
import fs from "fs";
import { chromium } from "playwright";

const HTML = "/tmp/qa6738/html";
const OUT = "/tmp/qa6738/shots";
const results = [];

// file stem -> [output name, the subject line the pod reported, expected copy]
const LEGS = [
  [
    "subscription_card_declined-card-control",
    "pr-6738-r4-declined-card-control",
    "Your card was declined.",
    "attempted to charge your card",
  ],
  [
    "subscription_card_declined-upi",
    "pr-6738-r4-declined-upi",
    "Your payment method needs attention.",
    "saved UPI payment method",
  ],
  [
    "subscription_card_declined_warning-card-control",
    "pr-6738-r4-warning-card-control",
    "Your card was declined.",
    "attempted to charge your card",
  ],
  [
    "subscription_card_declined_warning-upi",
    "pr-6738-r4-warning-upi",
    "Your payment method needs attention.",
    "saved UPI payment method",
  ],
];

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();

  for (const [stem, name, subject, expectCopy] of LEGS) {
    const html = fs.readFileSync(`${HTML}/${stem}.html`, "utf8");
    // Stamp the Subject line onto the frame: it is set in the mailer, not the template, so it
    // is invisible in the rendered body — and it is half of what this diff changes.
    const stamped = html.replace(
      /<body([^>]*)>/iu,
      `<body$1><div style="font:13px ui-monospace,Menlo,monospace;background:#111;color:#fff;padding:10px 14px">Subject: ${subject}</div>`,
    );
    const tmp = `/tmp/qa6738/html/_stamped-${stem}.html`;
    fs.writeFileSync(tmp, stamped);

    const ctx = await browser.newContext({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
    const page = await ctx.newPage();
    await page.goto(`file://${tmp}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(1500);

    const txt = await page.evaluate(() => document.body.innerText);
    if (!txt.includes(expectCopy)) throw new Error(`${name}: expected copy "${expectCopy}" absent`);
    if (!txt.includes(subject)) throw new Error(`${name}: subject stamp missing`);
    // negative assertion: the two variants must not both be present
    const other = expectCopy.includes("UPI") ? "attempted to charge your card" : "saved UPI payment method";
    if (txt.includes(other)) throw new Error(`${name}: BOTH variants rendered ("${other}" also present)`);

    const f = `${OUT}/${name}.png`;
    await page.screenshot({ path: f, fullPage: true });
    const line = `${name} subject="${subject}" has="${expectCopy}" lacks="${other}" ASSERTED OK -> ${f}`;
    console.log(line);
    results.push(line);
    await ctx.close();
  }
  await browser.close();
  fs.writeFileSync(`${OUT}/results.txt`, `${results.join("\n")}\n`);
})().catch((e) => {
  console.error(`FAILED: ${e.message}`);
  process.exit(1);
});
