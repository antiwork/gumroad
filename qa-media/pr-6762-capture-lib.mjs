// Playwright is deliberately not a repo dependency: these are one-shot QA captures
// for PR #6762 and qa-media is pruned after merge. Before running any script here:
//   npm install --no-save playwright@1.62.0 && npx playwright install chromium
import { chromium } from "playwright";

export const APEX = "fix-visible-gap-cursor-in-conten.apps.staging.gumroad.org";
export const ROOT = `https://${APEX}`;

export async function launch() {
  return chromium.launch();
}

export async function newCtx(browser, { width = 1440, height = 1100 } = {}) {
  const ctx = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: 2,
    ignoreHTTPSErrors: true,
  });
  await ctx.route("https://staging-assets.gumroad.com/**", async (route) => {
    const res = await route.fetch();
    await route.fulfill({ response: res, headers: { ...res.headers(), "access-control-allow-origin": "*" } });
  });
  return ctx;
}

export async function login(page) {
  await page.goto(`${ROOT}/login`, { waitUntil: "domcontentloaded", timeout: 120000 });
  const r = await page.evaluate(async () => {
    const csrf = document.querySelector('meta[name="csrf-token"]').content;
    const res = await fetch("/login", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, Accept: "application/json" },
      body: JSON.stringify({
        user: { login_identifier: "seller@gumroad.com", password: "password" },
        "g-recaptcha-response": "test",
      }),
    });
    return { status: res.status };
  });
  await page.goto(`${ROOT}/two-factor`, { waitUntil: "domcontentloaded", timeout: 120000 });
  const uid = await page.evaluate(() => {
    const el = document.querySelector("[data-page]");
    if (!el) return null;
    const p = JSON.parse(el.getAttribute("data-page"));
    return p?.props?.user_id ?? null;
  });
  if (uid) {
    await page.evaluate(async (userId) => {
      const csrf = document.querySelector('meta[name="csrf-token"]').content;
      await fetch("/two-factor", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, Accept: "application/json" },
        body: JSON.stringify({ token: "000000", user_id: userId }),
      });
    }, uid);
  }
  await page.goto(`${ROOT}/dashboard`, { waitUntil: "domcontentloaded", timeout: 120000 });
  return { loginStatus: r.status, uid, url: page.url() };
}
