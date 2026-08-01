/* eslint-disable no-console -- standalone QA capture script; stdout IS the evidence transcript. */
import fs from "fs";
import { launch, newCtx, login, ROOT } from "./pr-6762-capture-lib.mjs";

const OUT = "/tmp/pvw-20260731/after";
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
      tiptapTagStillPresent: !!document.querySelector("style[data-tiptap-style]"),
    };
  });

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

  const rev = await page.evaluate(() => document.querySelector("meta[name=revision]")?.content ?? null);
  if (!(await openGapCursor(page))) throw new Error(`${view.name}: gap cursor never appeared`);
  const served = await probe(page);
  results[view.name] = served;
  say(
    `${view.name.padEnd(8)} AFTER FIX  host=${served.hostW}px/${served.pmW}px pmPosition=${served.pmPosition} bar: width=${served.afterWidth} border=${served.afterBorderTop} anim=${served.afterAnimation} pageOverflow=${served.pageOverflow} tiptapTagStillInHead=${served.tiptapTagStillPresent} rev=${rev}`,
  );
  if (served.afterWidth === "20px") throw new Error(`${view.name}: STILL the upstream hairline`);

  await page.addStyleTag({
    content: ".ProseMirror-gapcursor::after{animation:none !important;visibility:visible !important}",
  });
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${OUT}/pr-6762-gap-cursor-after-${view.name}.png` });

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
    if (!t) return { found: false };
    const r = t.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return {
      found: true,
      pmPosition: getComputedStyle(pm).position,
      hitSwallowedByEditor: !!hit?.closest?.(".ProseMirror"),
    };
  });
  say(`empty-state  ${JSON.stringify(empty)}`);
  results["empty-state"] = empty;
  await page.screenshot({ path: `${OUT}/pr-6762-empty-state-upload-clickable.png` });
  await ctx.close();
}

await browser.close();
fs.writeFileSync(`${OUT}/pr-6762-browser-log-after.txt`, `${log.join("\n")}\n`);
say("DONE");
