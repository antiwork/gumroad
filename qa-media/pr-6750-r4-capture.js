// Playwright is deliberately not a repo dependency: these are one-shot QA captures
// for PR #6750 and qa-media is pruned after merge. Before running:
//   npm install --no-save playwright@1.62.0 && npx playwright install chromium
import fs from "node:fs";
import { chromium } from "playwright";

const BASE = "https://fix-gp1636-fixed-amount-once-per.apps.staging.gumroad.org";
const OUT = "/tmp/qa6750/shots";
const results = [];

const log = (s) => results.push(s);

// leg label -> expected totals, asserted in-script
const LEG = process.argv[2]; // "on" | "off"
const EXPECT = LEG === "on" ? { discount: "1", total: "19" } : { discount: "2", total: "18" };

async function readSummary(page) {
  return await page.evaluate(() => {
    // The country <select> floods innerText with ~250 option nodes; drop it first.
    document.querySelectorAll("select").forEach((s) => s.remove());
    const txt = document.body.innerText || "";
    // Match on whole lines so "Total" does not also match inside "Subtotal", and take
    // the next line that looks like an amount (the Discounts row interposes a code chip).
    const lines = txt.split("\n").map((l) => l.trim());
    const grab = (label) => {
      const i = lines.indexOf(label);
      if (i < 0) return null;
      for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
        const m = lines[j].match(/^US\$(-?[0-9.,]+)$/u);
        if (m) return m[1];
      }
      return null;
    };
    return {
      subtotal: grab("Subtotal"),
      discounts: (txt.match(/US\$-([0-9.,]+)/u) || [])[1] || null,
      total: grab("Total"),
      hasFixedChip: /QA6750FIXED/iu.test(txt),
      lines: [...new Set(txt.match(/QA6750 Widget [AB]/gu) || [])],
    };
  });
}

const run = async () => {
  fs.mkdirSync(OUT, { recursive: true });
  for (const dev of [
    { tag: "desktop", viewport: { width: 1440, height: 1000 } },
    { tag: "mobile-375", viewport: { width: 375, height: 812 }, isMobile: true, hasTouch: true },
  ]) {
    const browser = await chromium.launch();
    const ctx = await browser.newContext({ ...dev, deviceScaleFactor: 2 });
    const page = await ctx.newPage();

    // seed the cart: two $10 lines
    await page.goto(`${BASE}/checkout?product=demo&quantity=1`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3000);
    await page.goto(`${BASE}/checkout?product=c&quantity=1`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3000);
    // apply the code
    await page.goto(`${BASE}/checkout?code=QA6750FIXED`, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(6000);

    // hide the floating reCAPTCHA badge (covers the Total row at 375px; not touched by this PR)
    await page.addStyleTag({ content: ".grecaptcha-badge{display:none !important}" });

    const s = await readSummary(page);
    log(
      `${dev.tag} leg=${LEG} subtotal=${s.subtotal} discounts=-${s.discounts} total=${s.total} chip=${s.hasFixedChip} lines=${s.lines.length}`,
    );

    if (s.subtotal !== "20") throw new Error(`${dev.tag}/${LEG}: subtotal ${s.subtotal} != 20`);
    if (s.discounts !== EXPECT.discount)
      throw new Error(`${dev.tag}/${LEG}: discount -${s.discounts} != -${EXPECT.discount}`);
    if (s.total !== EXPECT.total) throw new Error(`${dev.tag}/${LEG}: total ${s.total} != ${EXPECT.total}`);
    if (!s.hasFixedChip) throw new Error(`${dev.tag}/${LEG}: QA6750FIXED chip missing`);
    if (s.lines.length < 2) throw new Error(`${dev.tag}/${LEG}: only ${s.lines.length} cart lines`);

    const f = `${OUT}/pr-6750-r4-flag-${LEG}-${dev.tag}.png`;
    await page.screenshot({ path: f });
    log(`${dev.tag} leg=${LEG} ASSERTED OK -> ${f}`);

    await browser.close();
  }
  fs.appendFileSync(`${OUT}/results.txt`, `${results.join("\n")}\n`);
};

// Surface the failing assertion to the shell: the whole point of the script is that a
// wrong total is a non-zero exit, not a screenshot of the wrong number.
await run().catch((e) => {
  fs.appendFileSync(`${OUT}/results.txt`, `FAILED: ${e.message}\n`);
  process.exit(1);
});
