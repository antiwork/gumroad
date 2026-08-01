// Upstream's `.ProseMirror-gapcursor` is a 20px black hairline — invisible on a dark background,
// so a leading file embed reads as an uneditable page (gumroad-private#1652). We restyle it as an
// accent bar.
//
// The subtle half is WHERE our rules have to win. `baseEditorOptions` sets `injectCSS: false`, but
// sibling editors constructed with a bare `useEditor` (ContentTab/PageTab's page-name field,
// Profile/EditPage's tab-name field) leave it at its `true` default, and Tiptap's `createStyleTag`
// appends ONE shared `style[data-tiptap-style]` to <head> at construction time. A bare
// `.ProseMirror-gapcursor` selector ties that tag on specificity and loses on document order, so
// the built app paints the black hairline while a selector-name-only test passes. These assertions
// compare computed SPECIFICITY against upstream rather than checking that names match.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const repoRoot = join(dirname(require.resolve("../../../package.json")));

const ourCss = readFileSync(join(repoRoot, "app/javascript/stylesheets/tailwind.css"), "utf8");
const editorSource = readFileSync(join(repoRoot, "app/javascript/components/RichTextEditor.tsx"), "utf8");
const tiptapCore = readFileSync(require.resolve("@tiptap/core"), "utf8");

const gapCursorSelectors = (css: string) =>
  [...css.matchAll(/(?<selector>[^{}]*\.ProseMirror-gapcursor[^{}]*)\{/gu)]
    // ::after and :after are the same pseudo-element; upstream writes the legacy one-colon form.
    .map((match) => (match.groups?.selector ?? "").trim().replace(/::/gu, ":").replace(/\s+/gu, " "))
    // Comments mentioning the class are not rules.
    .filter((selector) => !selector.includes("*") && !selector.includes("//"));

// (classes, elements) — enough for the selectors in play; pseudo-classes and pseudo-elements count
// as a class and an element respectively, matching the CSS cascade.
const specificity = (selector: string): [number, number] => [
  (selector.match(/\.[\w-]+|:(?!:)[\w-]+/gu) ?? []).length,
  (selector.match(/::[\w-]+/gu) ?? []).length,
];

// Our selectors are upstream's with one extra `.ProseMirror` qualifier bolted on the front, so
// stripping that qualifier maps ours back onto the upstream rule it has to beat. The `-` in
// `.ProseMirror-gapcursor` is neither whitespace nor a dot, so a bare host rule is left alone.
const key = (selector: string) => selector.replace(/^\.ProseMirror(\s+|(?=\.))/u, "");

describe("gap cursor styling", () => {
  it("still needs a local copy, because the editor suppresses Tiptap's stylesheet", () => {
    expect(editorSource).toMatch(/injectCSS:\s*false/u);
  });

  it("outweighs every gapcursor rule Tiptap injects at runtime, not just matches its names", () => {
    const upstream = gapCursorSelectors(tiptapCore);
    const ours = gapCursorSelectors(ourCss);

    // Guards the guard: if the scrape stops finding upstream rules the comparison below passes
    // vacuously and we ship the black hairline again.
    expect(upstream.length).toBeGreaterThanOrEqual(3);
    expect(upstream).toContain(".ProseMirror-focused .ProseMirror-gapcursor");

    for (const theirs of upstream) {
      const mine = ours.find((selector) => key(selector) === key(theirs));
      expect(mine, `no local rule covers upstream's \`${theirs}\``).toBeDefined();

      // Strictly greater on classes: equal weight would hand the decision to document order, and
      // their <style> tag is appended to <head> after our stylesheet link.
      const [theirClasses] = specificity(theirs);
      const [myClasses] = specificity(mine ?? "");
      expect(myClasses, `\`${mine}\` must outweigh upstream's \`${theirs}\``).toBeGreaterThan(theirClasses);
    }
  });

  it("keeps a sibling editor's injected stylesheet reachable, so the weight is actually needed", () => {
    // If nothing on the page injected the upstream rules, the extra weight would be dead code and
    // this whole file would be guarding nothing. Tiptap injects iff some editor omits the option.
    const pageTab = readFileSync(
      join(repoRoot, "app/javascript/components/ProductEdit/ContentTab/PageTab.tsx"),
      "utf8",
    );
    expect(pageTab).toMatch(/useEditor\(\{/u);
    expect(pageTab).not.toMatch(/injectCSS/u);
    expect(tiptapCore).toMatch(/data-tiptap-style/u);
  });

  it("positions the editor only while a caret exists, so the empty-state overlay stays clickable", () => {
    // .ProseMirror-gapcursor is `position: absolute` and needs the editor as its containing
    // block. Positioning .ProseMirror unconditionally also raises it above the empty-state
    // overlay rendered before it, so the editor's own empty <p> swallows clicks on "Upload your
    // files" (caught by spec/requests/products/edit/rich_text_editor_spec.rb).
    expect(ourCss).toMatch(/\.ProseMirror:has\(\.ProseMirror-gapcursor\)\s*\{[^}]*position:\s*relative/u);
    expect(ourCss).not.toMatch(/^\.ProseMirror\s*\{[^}]*position:\s*relative/mu);
  });

  it("pins both edges of the caret host, because ProseMirror's widget div is empty", () => {
    // `width: 100%` also fills the empty host, but it resolves against the padding box while the
    // box keeps its static content-edge left, so it overhangs padded editors and overflows.
    const host = /\.ProseMirror \.ProseMirror-gapcursor\s*\{(?<body>[^}]*)\}/u.exec(ourCss)?.groups?.body ?? "";
    expect(host).toMatch(/left:\s*0/u);
    expect(host).toMatch(/right:\s*0/u);
    // Anchored to a declaration start so the word "width" in the comment above doesn't match.
    expect(host).not.toMatch(/^\s*width:/mu);
  });

  it("draws the caret with the accent colour, so it stays visible in dark mode", () => {
    const rule = /\.ProseMirror \.ProseMirror-gapcursor::after\s*\{(?<body>[^}]*)\}/u.exec(ourCss)?.groups?.body ?? "";
    expect(rule).toMatch(/border-top:[^;]*rgb\(var\(--accent\)\)/u);
    expect(rule).not.toMatch(/black/u);
    // The bar is absolutely positioned with empty content, so it shrink-to-fits to 0 and paints
    // nothing without this — the original defect, which every other assertion here passes over.
    expect(rule).toMatch(/width:\s*100%/u);
  });
});
