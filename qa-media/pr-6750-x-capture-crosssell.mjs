/* eslint-disable no-console */
import { chromium } from "playwright";
import fs from "fs";

const ROOT = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/Users/gumclaw/qa/pr6750x";
fs.mkdirSync(OUT, { recursive: true });
const log = (s) => console.log("MARK6750C " + s);

const br = await chromium.launch();

async function leg(name, viewport) {
  const ctx = await br.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(120000);

  for (const slug of ["demo", "c"]) {
    await page.goto(`${ROOT}/checkout?product=${slug}`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3500);
  }
  await page.goto(`${ROOT}/checkout?code=QA6750FIXED`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(6000);

  // Scroll the cross-sell heading to the top of the frame so its card + price are in shot.
  const ok = await page.evaluate(() => {
    const h = [...document.querySelectorAll("h1,h2,h3,h4")].find((e) =>
      /also bought/i.test(e.textContent || ""),
    );
    if (!h) return false;
    window.scrollTo(0, window.scrollY + h.getBoundingClientRect().top - 20);
    return true;
  });
  if (!ok) throw new Error(`${name}: cross-sell heading not found`);
  await page.waitForTimeout(1500);

  // Read the cross-sell card's own rendered price strings.
  const card = await page.evaluate(() => {
    const h = [...document.querySelectorAll("h1,h2,h3,h4")].find((e) =>
      /also bought/i.test(e.textContent || ""),
    );
    let n = h.nextElementSibling;
    const txt = n ? n.innerText : "";
    return { text: txt, money: [...txt.matchAll(/\$-?[\d.,]+/g)].map((x) => x[0]) };
  });
  log(`${name} crosssell_card_text=${JSON.stringify(card.text)}`);
  log(`${name} crosssell_card_money=${JSON.stringify(card.money)}`);

  await page.screenshot({ path: `${OUT}/${name}.png` });
  await ctx.close();
}

await leg("pr-6750-x-crosssell-card-desktop", { width: 1280, height: 900 });
await leg("pr-6750-x-crosssell-card-mobile", { width: 375, height: 812 });

await br.close();
log("DONE");
