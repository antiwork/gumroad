// The rich text editor sets `injectCSS: false`, which suppresses Tiptap's own stylesheet. That
// stylesheet is the only place `.ProseMirror-gapcursor` is defined upstream, so without a local
// replacement the gap cursor is `display: none` and clicking beside a leading file embed gives
// the seller no caret and no feedback (gumroad-private#1652).
//
// This asserts the two halves that have to stay together: the option that creates the gap, and
// the rules that fill it. Reading Tiptap's own stylesheet rather than hardcoding selector names
// means a dependency bump that renames or adds a gapcursor rule reddens here.
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
  new Set(
    [...css.matchAll(/(?<selector>[^{}]*\.ProseMirror-gapcursor[^{}]*)\{/gu)].map((match) =>
      // ::after and :after are the same pseudo-element; upstream writes the legacy one-colon form.
      (match.groups?.selector ?? "").trim().replace(/::/gu, ":").replace(/\s+/gu, " "),
    ),
  );

describe("gap cursor styling", () => {
  it("still needs a local copy, because the editor suppresses Tiptap's stylesheet", () => {
    expect(editorSource).toMatch(/injectCSS:\s*false/u);
  });

  it("defines every gapcursor rule Tiptap would have injected", () => {
    const upstream = gapCursorSelectors(tiptapCore);

    // Guards the guard: if the scrape stops finding upstream rules, the comparison below passes
    // vacuously and we ship an invisible caret again.
    expect(upstream.size).toBeGreaterThanOrEqual(3);
    expect(upstream).toContain(".ProseMirror-focused .ProseMirror-gapcursor");

    for (const selector of upstream) expect(gapCursorSelectors(ourCss)).toContain(selector);
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
    const host = /\.ProseMirror-gapcursor\s*\{(?<body>[^}]*)\}/u.exec(ourCss)?.groups?.body ?? "";
    expect(host).toMatch(/left:\s*0/u);
    expect(host).toMatch(/right:\s*0/u);
    // Anchored to a declaration start so the word "width" in the comment above doesn't match.
    expect(host).not.toMatch(/^\s*width:/mu);
  });

  it("draws the caret with the accent colour, so it stays visible in dark mode", () => {
    const rule = /\.ProseMirror-gapcursor::after\s*\{(?<body>[^}]*)\}/u.exec(ourCss)?.groups?.body ?? "";
    expect(rule).toMatch(/border-top:[^;]*rgb\(var\(--accent\)\)/u);
    expect(rule).not.toMatch(/black/u);
    // The bar is absolutely positioned with empty content, so it shrink-to-fits to 0 and paints
    // nothing without this — the original defect, which every other assertion here passes over.
    expect(rule).toMatch(/width:\s*100%/u);
  });
});
