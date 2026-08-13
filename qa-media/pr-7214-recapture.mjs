/* eslint-disable no-console */
// PR 7214 round 2: recapture the Meet Gumhead card after the cuter/3D-forward redesign.
import fs from "fs";
import { chromium } from "playwright";

const HOST = "https://gumclaw-feature-gumhead-dashboar.apps.staging.gumroad.org";
const OUT = "/tmp/pw7214";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log(`MARK7214 ${s}`);

const br = await chromium.launch({ channel: "chrome" });

async function login(ctx) {
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);
  await page.goto(`${HOST}/login`, { waitUntil: "domcontentloaded" });
  await page.getByLabel("Email").fill("seller@gumroad.com");
  await page.getByLabel("Password").fill("password");
  await page.getByRole("button", { name: "Login" }).click();
  // 2FA
  try {
    await page.waitForURL(/two-factor/u, { timeout: 15000 });
    await page.locator("input").first().fill("000000");
    await page.getByRole("button", { name: /Login|Verify/u }).click();
  } catch {
    log("no 2FA step");
  }
  await page.waitForTimeout(5000);
  log(`post-login url=${page.url()}`);
  return page;
}

async function shot(page, name, dark, viewport) {
  await page.emulateMedia({ colorScheme: dark ? "dark" : "light" });
  await page.setViewportSize(viewport);
  await page.goto(`${HOST}/dashboard`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(6000);
  const hasCard = await page.getByText("Meet Gumhead").count();
  log(`${name} meet-gumhead-count=${hasCard}`);
  const png = `${OUT}/pr-7214-${name}.png`;
  await page.screenshot({ path: png });
  log(`shot ${png}`);
}

const ctx = await br.newContext({ viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 2 });
const page = await login(ctx);
await shot(page, "dashboard-flag-on-desktop-light", false, { width: 1440, height: 1100 });
await shot(page, "dashboard-flag-on-desktop-dark", true, { width: 1440, height: 1100 });
await shot(page, "dashboard-flag-on-mobile-light", false, { width: 390, height: 900 });
await shot(page, "dashboard-flag-on-mobile-dark", true, { width: 390, height: 900 });
await br.close();
log("done");
