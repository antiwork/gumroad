/* eslint-disable no-console -- standalone QA capture script; stdout IS the evidence transcript. */
import fs from "fs";
import { launch, newCtx, login, ROOT } from "./pr-6762-capture-lib.mjs";

const OUT = "/tmp/pvw-20260731/shots";
fs.mkdirSync(OUT, { recursive: true });
const log = [];
const say = (s) => {
  console.log(s);
  log.push(s);
};

const browser = await launch();

const probe = (page) =>
  page.evaluate(() => {
    const el = document.querySelector(".ProseMirror-gapcursor");
    if (!el) return { present: false };
    const after = getComputedStyle(el, "::after");
    const r = el.getBoundingClientRect();
    const pm = el.closest(".ProseMirror");
    const pr = pm.getBoundingClientRect();
    return {
      present: true,
      display: getComputedStyle(el).display,
      hostW: Math.round(r.width),
      pmW: Math.round(pr.width),
      pmPosition: getComputedStyle(pm).position,
      afterWidth: after.width,
      afterBorderTop: `${after.borderTopWidth} ${after.borderTopStyle} ${after.borderTopColor}`,
      afterAnimation: after.animationName,
      pageOverflow: `${document.scrollingElement.scrollWidth}/${document.scrollingElement.clientWidth}`,
    };
  });

// Walk the selection into the leading gap above the file embed.
async function openGapCursor(page) {
  const para = await page.evaluate(() => {
    const pm = document.querySelector(".ProseMirror");
    const p = [...pm.children].find((c) => c.tagName === "P");
    if (!p) return null;
    const r = p.getBoundingClientRect();
    return { x: r.x + 20, y: r.y + r.height / 2 };
  });
  if (!para) throw new Error("no paragraph to seed the selection from");
  await page.mouse.click(para.x, para.y);
  for (let k = 0; k < 5; k++) {
    await page.keyboard.press("ArrowUp");
    await page.waitForTimeout(450);
    if ((await probe(page)).present) return true;
  }
  return false;
}

const results = {};

for (const view of [
  { name: "desktop", width: 1440, height: 1100 },
  { name: "mobile", width: 375, height: 812 },
]) {
  const ctx = await newCtx(browser, view);
  const page = await ctx.newPage();
  await login(page);
  await page.goto(`${ROOT}/products/demo/edit/content`, { waitUntil: "domcontentloaded", timeout: 120000 });
  await page.waitForTimeout(8000);

  // Which gapcursor rule sets are live, and in which order?
  const sheets = await page.evaluate(() =>
    [...document.styleSheets]
      .map((s) => {
        let rules = [];
        try {
          rules = [...s.cssRules].map((r) => r.cssText).filter((t) => /ProseMirror-gapcursor::after/u.test(t));
        } catch {
          return null;
        }
        return rules.length
          ? { source: s.href ? "link (PR's tailwind.css)" : "<style> (Tiptap injectCSS)", rules }
          : null;
      })
      .filter(Boolean),
  );
  say(`${view.name} gapcursor ::after rule sets, in cascade order:`);
  for (const s of sheets) say(`  ${s.source}  ${s.rules.join(" ")}`);

  if (!(await openGapCursor(page))) throw new Error(`${view.name}: gap cursor never appeared`);
  const served = await probe(page);
  results[`${view.name}/as-served`] = served;
  say(
    `${view.name.padEnd(8)} AS SERVED     host=${served.hostW}px/${served.pmW}px pmPosition=${served.pmPosition} bar: width=${served.afterWidth} border=${served.afterBorderTop} anim=${served.afterAnimation} pageOverflow=${served.pageOverflow}`,
  );

  await page.addStyleTag({
    content: ".ProseMirror-gapcursor::after{animation:none !important;visibility:visible !important}",
  });
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${OUT}/pr-6762-gap-cursor-as-served-${view.name}.png` });
  const pmEl = await page.$(".ProseMirror");
  await pmEl.screenshot({ path: `${OUT}/pr-6762-gap-cursor-as-served-${view.name}-editor.png` });

  // CONTROL: disable the Tiptap-injected <style> so only the PR's rules apply.
  await page.evaluate(() => {
    for (const s of document.styleSheets) {
      if (s.href) continue;
      try {
        if ([...s.cssRules].some((r) => /ProseMirror-cursor-blink/u.test(r.cssText))) s.ownerNode.disabled = true;
      } catch {
        /* cross-origin sheet */
      }
    }
  });
  await page.waitForTimeout(400);
  const intended = await probe(page);
  results[`${view.name}/pr-rules-only`] = intended;
  say(
    `${view.name.padEnd(8)} PR RULES ONLY host=${intended.hostW}px/${intended.pmW}px pmPosition=${intended.pmPosition} bar: width=${intended.afterWidth} border=${intended.afterBorderTop} anim=${intended.afterAnimation} pageOverflow=${intended.pageOverflow}`,
  );
  await page.screenshot({ path: `${OUT}/pr-6762-gap-cursor-pr-rules-only-${view.name}.png` });
  const pmEl2 = await page.$(".ProseMirror");
  await pmEl2.screenshot({ path: `${OUT}/pr-6762-gap-cursor-pr-rules-only-${view.name}-editor.png` });

  // typing in the gap still inserts a paragraph
  const before = await page.evaluate(() => document.querySelector(".ProseMirror").children.length);
  await page.keyboard.type("typed in the gap");
  await page.waitForTimeout(900);
  const typed = await page.evaluate(() => ({
    n: document.querySelector(".ProseMirror").children.length,
    first: document.querySelector(".ProseMirror").firstElementChild.innerText.slice(0, 40),
  }));
  say(`${view.name.padEnd(8)} typing in the gap: children ${before} -> ${typed.n}, first node now "${typed.first}"`);
  await page.screenshot({ path: `${OUT}/pr-6762-typed-in-gap-${view.name}.png` });

  await ctx.close();
}

// Empty-state regression check: "Upload your files" must stay clickable (4df2748).
{
  const ctx = await newCtx(browser, { width: 1440, height: 1100 });
  const page = await ctx.newPage();
  await login(page);
  await page.goto(`${ROOT}/products/membershipdemo/edit/content`, { waitUntil: "domcontentloaded", timeout: 120000 });
  await page.waitForTimeout(8000);
  const empty = await page.evaluate(() => {
    const pm = document.querySelector(".ProseMirror");
    const t = [...document.querySelectorAll("button, a, div, span")].find((e) =>
      /Upload your files/iu.test(e.textContent ?? ""),
    );
    if (!t) return { found: false, pmPosition: pm ? getComputedStyle(pm).position : null };
    const r = t.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return {
      found: true,
      pmPosition: getComputedStyle(pm).position,
      hitTagged: hit?.tagName,
      hitIsInsideOverlay:
        !!hit?.closest?.("[class]") && /Upload your files/iu.test(hit.closest("div")?.textContent ?? ""),
      hitSwallowedByEditor: !!hit?.closest?.(".ProseMirror"),
    };
  });
  say(`empty-state  ${JSON.stringify(empty)}`);
  results["empty-state"] = empty;
  await page.screenshot({ path: `${OUT}/pr-6762-empty-state-upload-clickable.png` });
  await ctx.close();
}

await browser.close();
fs.writeFileSync("/tmp/pvw-20260731/results.json", JSON.stringify(results, null, 2));
fs.writeFileSync(`${OUT}/pr-6762-browser-log.txt`, `${log.join("\n")}\n`);
say("DONE");
