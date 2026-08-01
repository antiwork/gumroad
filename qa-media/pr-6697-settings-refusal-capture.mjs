import fs from "fs";
import path from "path";

import { BASE, launch, login, finish } from "./pr-6697-preview-qa-lib.mjs";

const OUT = "/tmp/shots6697/out";
fs.mkdirSync(OUT, { recursive: true });
const REFUSED = "refused-qa6697@example.com";

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
    // The settings layout scrolls in an INNER container.
    document.querySelectorAll("*").forEach((el) => {
      if (el.scrollTop > 0) el.scrollTop = 0;
    });
    window.scrollTo(0, 0);
  }, lines);
  await page.waitForTimeout(400);
}

async function shot(page, name) {
  const f = path.join(OUT, `${name}.png`);
  await page.screenshot({ path: f, fullPage: false });
  const kb = Math.round(fs.statSync(f).size / 1024);
  process.stdout.write(`MARK shot ${name} ${kb}KB\n`);
  return f;
}

// Read the alert/status text the app rendered.
async function alertText(page) {
  return await page.evaluate(() => {
    const els = Array.from(document.querySelectorAll('[role="alert"],[role="status"]'));
    return els
      .map((e) => e.innerText.trim())
      .filter(Boolean)
      .join(" | ");
  });
}

async function leg({ width, tag }) {
  const { browser, ctx, page } = await launch({ video: false, width, mobile: width === 375 });
  page.on("pageerror", (e) => process.stdout.write(`PAGEERROR ${tag} ${String(e)}\n`));
  page.setDefaultTimeout(90000);
  const ok = await login(page);
  if (!ok) throw new Error("login failed");

  await page.goto(`${BASE}/settings/payments`, { waitUntil: "domcontentloaded", timeout: 120000 });
  await page.waitForFunction(() => document.querySelectorAll("input").length > 3, { timeout: 90000 });
  await page.waitForTimeout(3500);

  const props = await page.evaluate(() => {
    const p = JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props;
    return { modal: p.should_show_country_modal, paypal_address: p.paypal_address };
  });
  if (props.modal) throw new Error("ABORT country modal is showing");
  process.stdout.write(`MARK ${tag} props=${JSON.stringify(props)}\n`);

  // The PayPal method must already be the selected payout method (seeded payment_address).
  const emailId = await page.evaluate(() => {
    const i = Array.from(document.querySelectorAll('input[type="email"]')).find((e) => /paypal-email/u.test(e.id));
    return i ? i.id : null;
  });
  if (!emailId) throw new Error("ABORT no paypal email input");

  // Re-type the SAME permanently refused address and submit.
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
    { id: emailId, val: REFUSED },
  );
  await page.waitForTimeout(600);

  const typed = await page.evaluate((id) => document.getElementById(id).value, emailId);
  process.stdout.write(`MARK ${tag} typed=${typed}\n`);
  if (typed !== REFUSED) throw new Error("ABORT typed value did not stick");

  let saveStatus = null;
  page.on("response", (r) => {
    if (/\/settings\/payments/u.test(r.url()) && r.request().method() !== "GET") saveStatus = r.status();
  });

  await page.getByRole("button", { name: "Update settings" }).click();
  await page.waitForTimeout(5000);

  const alert = await alertText(page);
  process.stdout.write(`MARK ${tag} alert=${JSON.stringify(alert)} http=${saveStatus}\n`);
  const EXPECTED = "PayPal won't accept payouts to that account. Please use a different PayPal account.";
  if (!alert.includes(EXPECTED)) throw new Error(`ABORT expected refusal copy, got: ${alert}`);

  await overlay(page, [
    `[harness overlay — values read from the live page, ${tag}]`,
    `re-saved the permanently refused address: ${REFUSED}`,
    `standing rejection: PAYPAL 3148 (retry-blocking)`,
    `app response: ${alert}`,
  ]);
  await shot(page, `pr-6697-${tag}-refused-address-rejected`);

  await finish(page, ctx, browser);
  return alert;
}

const a = await leg({ width: null, tag: "desktop" });
const b = await leg({ width: 375, tag: "mobile375" });
process.stdout.write(`MARK done desktop_alert_matches=${a === b}\n`);
