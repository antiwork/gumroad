/* eslint-disable no-console -- standalone QA probe; stdout IS the evidence transcript. */
import { launch, newCtx, login, ROOT } from "./pr-6762-capture-lib.mjs";

const browser = await launch();
const ctx = await newCtx(browser);
const page = await ctx.newPage();
await login(page);
await page.goto(`${ROOT}/products/demo/edit/content`, { waitUntil: "domcontentloaded", timeout: 120000 });
await page.waitForTimeout(8000);

const out = await page.evaluate(() => {
  const nodes = [...document.querySelectorAll("head link[rel=stylesheet], head style")];
  const linkIdx = nodes.findIndex((n) => n.tagName === "LINK" && /design-/u.test(n.href ?? ""));
  const tiptapIdx = nodes.findIndex((n) => n.tagName === "STYLE" && /ProseMirror-cursor-blink/u.test(n.textContent));
  const tt = nodes[tiptapIdx];
  return {
    headOrder: { prTailwindLinkIndex: linkIdx, tiptapStyleIndex: tiptapIdx, tiptapIsLater: tiptapIdx > linkIdx },
    tiptapNodeAttrs: tt ? [...tt.attributes].map((a) => `${a.name}="${a.value}"`) : null,
    tiptapMarkers: tt
      ? {
          hasTippy: /tippy-box/u.test(tt.textContent),
          hasHideselection: /ProseMirror-hideselection/u.test(tt.textContent),
        }
      : null,
    // Both selectors are identical specificity, so document order alone decides.
    winner: (() => {
      const el = document.createElement("div");
      el.className = "ProseMirror-gapcursor";
      document.body.appendChild(el);
      const w = getComputedStyle(el, "::after").borderTopWidth;
      el.remove();
      return w;
    })(),
    editorsOnPage: document.querySelectorAll(".ProseMirror").length,
    // the pages sidebar rename editors are the other useEditor() callers on this route
    pageTabEditors: [...document.querySelectorAll(".ProseMirror")].map((p) =>
      p.closest("[role=listitem], li, [data-page-tab]") ? "sidebar" : "content",
    ),
  };
});
console.log(JSON.stringify(out, null, 1));
await browser.close();
