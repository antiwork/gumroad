// Reusable Playwright helpers for Gumroad preview-app QA.
// Usage: set PREVIEW_URL env var, then
// `const { launch, login, snap, finish } = require('./lib')` from one-shot step scripts.
// No `npm i` needed in the step dir — the require below falls back to the global install.
//
// HEADED=1 launches a visible browser — REQUIRED for buyer checkout flows:
// checkout reCAPTCHA Enterprise rejects headless Chromium ("could not verify the CAPTCHA").
// Login/admin flows are fine headless (the login CAPTCHA test key accepts anything).

// Playwright is CommonJS and usually only present in the HOME node_modules, not in the
// isolated /tmp step dir. Resolve locally first, then fall back — an ESM
// `import { chromium }` throws "Named export 'chromium' not found" either way.
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  ({ chromium } = require(require('os').homedir() + '/node_modules/playwright/index.js'));
}
const path = require('path');
const fs = require('fs');

const BASE = process.env.PREVIEW_URL; // e.g. https://<user>-<branch>.apps.staging.gumroad.org
const OUT = path.join(__dirname, 'out');
fs.mkdirSync(OUT, { recursive: true });

// deviceScaleFactor 2 is the standing requirement for every committed qa-media shot
// (Sahil 2026-07-19). Tell that it was dropped: crops land ~12KB instead of ~31KB.
// `width` overrides the viewport for a specific breakpoint (mobile surfaces: width 375).
async function launch({ mobile = false, dark = false, video = true, width = null } = {}) {
  const viewport = width
    ? { width, height: 812 }
    : (mobile ? { width: 390, height: 844 } : { width: 1440, height: 900 });
  const browser = await chromium.launch({ headless: process.env.HEADED ? false : true });
  const ctx = await browser.newContext({
    viewport,
    deviceScaleFactor: 2,
    colorScheme: dark ? 'dark' : 'light',
    ...(video ? { recordVideo: { dir: OUT, size: viewport } } : {}),
    ...(mobile ? { isMobile: true, hasTouch: true } : {}),
  });
  const page = await ctx.newPage();
  page.setDefaultTimeout(30000);
  await fixAssetCors(ctx);
  return { browser, ctx, page, viewport };
}

// staging-assets.gumroad.com only sends ACAO for known staging hosts; per-PR preview
// subdomains (seller.<preview>...) get blocked -> blank pages. Inject a permissive header.
async function fixAssetCors(ctx) {
  await ctx.route('https://staging-assets.gumroad.com/**', async (route) => {
    try {
      const res = await route.fetch();
      await route.fulfill({ response: res, headers: { ...res.headers(), 'access-control-allow-origin': '*' } });
    } catch (e) {
      await route.continue();
    }
  });
}

// JSON login + 2FA. POSTs may return 404 while still setting the cookie —
// success is judged by /dashboard not bouncing to /login.
// NOTE: 'domcontentloaded' everywhere, NOT 'networkidle' — preview apps keep
// long-lived analytics/telemetry connections open and 'networkidle' times out.
async function login(page, email = 'seller@gumroad.com', password = 'password') {
  await page.goto(BASE + '/login', { waitUntil: 'domcontentloaded' });
  const csrf = await page.getAttribute('meta[name="csrf-token"]', 'content');
  await page.evaluate(async ({ csrf, email, password }) => {
    await fetch('/login', {
      method: 'POST',
      headers: { 'X-CSRF-Token': csrf, 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ user: { login_identifier: email, password }, 'g-recaptcha-response': 'test' }),
    });
  }, { csrf, email, password });

  await page.goto(BASE + '/two-factor?next=%2Fdashboard', { waitUntil: 'domcontentloaded' });
  if (page.url().includes('two-factor')) {
    const csrf2 = await page.getAttribute('meta[name="csrf-token"]', 'content');
    const dataPage = await page.getAttribute('[data-page]', 'data-page').catch(() => null);
    let userId = null;
    if (dataPage) { try { userId = JSON.parse(dataPage).props.user_id; } catch (e) {} }
    await page.evaluate(async ({ csrf2, userId }) => {
      await fetch('/two-factor', {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrf2, 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ token: '000000', user_id: userId }),
      });
    }, { csrf2, userId });
  }
  await page.goto(BASE + '/dashboard', { waitUntil: 'domcontentloaded' });
  return !page.url().includes('/login');
}

// Enable a Flipper feature flag (fresh previews have zero features configured).
async function enableFlag(page, flag) {
  await page.goto(BASE + '/admin/features/features/new', { waitUntil: 'domcontentloaded' });
  const nameInput = await page.$('input[name="value"]');
  if (nameInput) {
    await nameInput.fill(flag);
    await page.click('input[type="submit"], button[type="submit"]');
    await page.waitForLoadState('domcontentloaded');
  }
  await page.goto(BASE + '/admin/features/features/' + flag, { waitUntil: 'domcontentloaded' });
  const btn = await page.$('form[action*="boolean"] input[type="submit"][value*="Enable"], form[action*="boolean"] button:has-text("Enable")');
  if (btn) { await btn.click(); await page.waitForLoadState('domcontentloaded'); }
  return await page.evaluate(() => document.body.innerText.match(/Fully enabled|Disabled|Conditionally/i)?.[0] || 'unknown');
}

async function snap(page, name, full = true) {
  const f = path.join(OUT, name + '.png');
  await page.screenshot({ path: f, fullPage: full });
  return f;
}

async function finish(page, ctx, browser) {
  await page.close();
  let video = null;
  try { video = await page.video().path(); } catch (e) {}
  await ctx.close();
  await browser.close();
  return video;
}

module.exports = { BASE, OUT, launch, login, enableFlag, snap, finish, fixAssetCors };
