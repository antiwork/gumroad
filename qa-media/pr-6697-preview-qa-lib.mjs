// Reusable Playwright helpers for Gumroad preview-app QA.
// Usage: set PREVIEW_URL env var, then
// `import { launch, login, snap, finish } from "./pr-6697-preview-qa-lib.mjs"` from step scripts.
//
// HEADED=1 launches a visible browser — REQUIRED for buyer checkout flows:
// checkout reCAPTCHA Enterprise rejects headless Chromium ("could not verify the CAPTCHA").
// Login/admin flows are fine headless (the login CAPTCHA test key accepts anything).

import fs from "fs";
import path from "path";
import { chromium } from "playwright";
import { fileURLToPath } from "url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const BASE = process.env.PREVIEW_URL; // e.g. https://<user>-<branch>.apps.staging.gumroad.org
export const OUT = path.join(HERE, "out");
fs.mkdirSync(OUT, { recursive: true });

// staging-assets.gumroad.com only sends ACAO for known staging hosts; per-PR preview
// subdomains (seller.<preview>...) get blocked -> blank pages. Inject a permissive header.
export async function fixAssetCors(ctx) {
  await ctx.route("https://staging-assets.gumroad.com/**", async (route) => {
    try {
      const res = await route.fetch();
      await route.fulfill({ response: res, headers: { ...res.headers(), "access-control-allow-origin": "*" } });
    } catch {
      await route.continue();
    }
  });
}

// deviceScaleFactor 2 is the standing requirement for every committed qa-media shot
// (Sahil 2026-07-19). Tell that it was dropped: crops land ~12KB instead of ~31KB.
// `width` overrides the viewport for a specific breakpoint (mobile surfaces: width 375).
export async function launch({ mobile = false, dark = false, video = true, width = null } = {}) {
  const viewport = width ? { width, height: 812 } : mobile ? { width: 390, height: 844 } : { width: 1440, height: 900 };
  const browser = await chromium.launch({ headless: !process.env.HEADED });
  const ctx = await browser.newContext({
    viewport,
    deviceScaleFactor: 2,
    colorScheme: dark ? "dark" : "light",
    ...(video ? { recordVideo: { dir: OUT, size: viewport } } : {}),
    ...(mobile ? { isMobile: true, hasTouch: true } : {}),
  });
  const page = await ctx.newPage();
  page.setDefaultTimeout(30000);
  await fixAssetCors(ctx);
  return { browser, ctx, page, viewport };
}

// JSON login + 2FA. POSTs may return 404 while still setting the cookie —
// success is judged by /dashboard not bouncing to /login.
// NOTE: 'domcontentloaded' everywhere, NOT 'networkidle' — preview apps keep
// long-lived analytics/telemetry connections open and 'networkidle' times out.
export async function login(page, email = "seller@gumroad.com", password = "password") {
  await page.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" });
  const csrf = await page.getAttribute('meta[name="csrf-token"]', "content");
  await page.evaluate(
    async ({ csrf, email, password }) => {
      await fetch("/login", {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ user: { login_identifier: email, password }, "g-recaptcha-response": "test" }),
      });
    },
    { csrf, email, password },
  );

  await page.goto(`${BASE}/two-factor?next=%2Fdashboard`, { waitUntil: "domcontentloaded" });
  if (page.url().includes("two-factor")) {
    const csrf2 = await page.getAttribute('meta[name="csrf-token"]', "content");
    const dataPage = await page.getAttribute("[data-page]", "data-page").catch(() => null);
    let userId = null;
    if (dataPage) {
      try {
        userId = JSON.parse(dataPage).props.user_id;
      } catch {
        userId = null;
      }
    }
    await page.evaluate(
      async ({ csrf2, userId }) => {
        await fetch("/two-factor", {
          method: "POST",
          headers: { "X-CSRF-Token": csrf2, "Content-Type": "application/json", Accept: "application/json" },
          body: JSON.stringify({ token: "000000", user_id: userId }),
        });
      },
      { csrf2, userId },
    );
  }
  await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded" });
  return !page.url().includes("/login");
}

// Enable a Flipper feature flag (fresh previews have zero features configured).
export async function enableFlag(page, flag) {
  await page.goto(`${BASE}/admin/features/features/new`, { waitUntil: "domcontentloaded" });
  const nameInput = await page.$('input[name="value"]');
  if (nameInput) {
    await nameInput.fill(flag);
    await page.click('input[type="submit"], button[type="submit"]');
    await page.waitForLoadState("domcontentloaded");
  }
  await page.goto(`${BASE}/admin/features/features/${flag}`, { waitUntil: "domcontentloaded" });
  const btn = await page.$(
    'form[action*="boolean"] input[type="submit"][value*="Enable"], form[action*="boolean"] button:has-text("Enable")',
  );
  if (btn) {
    await btn.click();
    await page.waitForLoadState("domcontentloaded");
  }
  return await page.evaluate(
    () => document.body.innerText.match(/Fully enabled|Disabled|Conditionally/iu)?.[0] || "unknown",
  );
}

export async function snap(page, name, full = true) {
  const f = path.join(OUT, `${name}.png`);
  await page.screenshot({ path: f, fullPage: full });
  return f;
}

export async function finish(page, ctx, browser) {
  await page.close();
  let video = null;
  try {
    video = await page.video().path();
  } catch {
    video = null;
  }
  await ctx.close();
  await browser.close();
  return video;
}
