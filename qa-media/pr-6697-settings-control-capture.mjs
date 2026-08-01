import fs from "fs";
import path from "path";

import { BASE, launch, login, finish } from "./pr-6697-preview-qa-lib.mjs";

const OUT = "/tmp/shots6697/out";
const REFUSED = "refused-qa6697@example.com";
const CLEAN = "clean-qa6697@example.com";

async function overlay(page, lines) {
  await page.evaluate((lines) => {
    document.querySelectorAll(".qa-harness-overlay").forEach((e) => e.remove());
    const d = document.createElement("div");
    d.className = "qa-harness-overlay";
    d.style.cssText =
      "position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;" +
      "font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;padding:6px 10px;white-space:pre-wrap";
    d.textContent = lines.join("\n");
    document.body.prepend(d);
    document.querySelectorAll("*").forEach((el) => {
      if (el.scrollTop > 0) el.scrollTop = 0;
    });
    window.scrollTo(0, 0);
  }, lines);
  await page.waitForTimeout(400);
}

const { browser, ctx, page } = await launch({ video: false });
page.on("pageerror", (e) => process.stdout.write(`PAGEERROR ${String(e)}\n`));
page.setDefaultTimeout(90000);
if (!(await login(page))) throw new Error("login failed");

await page.goto(`${BASE}/settings/payments`, { waitUntil: "domcontentloaded", timeout: 120000 });
await page.waitForFunction(() => document.querySelectorAll("input").length > 3, { timeout: 90000 });
await page.waitForTimeout(3500);

const emailId = await page.evaluate(() => {
  const i = Array.from(document.querySelectorAll('input[type="email"]')).find((e) => /paypal-email/u.test(e.id));
  return i ? i.id : null;
});
const before = await page.evaluate((id) => document.getElementById(id).value, emailId);
process.stdout.write(`MARK control before=${before}\n`);
if (before !== REFUSED) throw new Error("ABORT precondition: refused address is not on the account");

await page.evaluate(
  ({ id, val }) => {
    const el = document.getElementById(id);
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
    setter.call(el, "");
    el.dispatchEvent(new Event("input", { bubbles: true }));
    setter.call(el, val);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  },
  { id: emailId, val: CLEAN },
);
await page.waitForTimeout(600);

await page.getByRole("button", { name: "Update settings" }).click();
await page.waitForTimeout(5000);

const alert = await page.evaluate(() =>
  Array.from(document.querySelectorAll('[role="alert"],[role="status"]'))
    .map((e) => e.innerText.trim())
    .filter(Boolean)
    .join(" | "),
);
process.stdout.write(`MARK control alert=${JSON.stringify(alert)}\n`);
if (/won't accept payouts/u.test(alert))
  throw new Error("ABORT a DIFFERENT address was refused — guard is not address-keyed");

await page.reload({ waitUntil: "domcontentloaded" });
await page.waitForFunction(() => document.querySelectorAll("input").length > 3, { timeout: 90000 });
await page.waitForTimeout(3000);
const persisted = await page.evaluate(
  () => JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.paypal_address,
);
process.stdout.write(`MARK control persisted=${persisted}\n`);
if (persisted !== CLEAN) throw new Error(`ABORT the clean address did not persist: ${persisted}`);

await overlay(page, [
  "[harness overlay — values read from the live page, control leg]",
  `a DIFFERENT PayPal address saves normally: ${CLEAN}`,
  `app response: ${alert || "(no error)"}`,
  `re-read after reload — props.paypal_address = ${persisted}`,
]);
const f = path.join(OUT, "pr-6697-desktop-different-address-accepted.png");
await page.screenshot({ path: f, fullPage: false });
process.stdout.write(`MARK shot control ${Math.round(fs.statSync(f).size / 1024)}KB\n`);

await finish(page, ctx, browser);
