import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as sass from "sass";
import { describe, expect, it } from "vitest";

// The entrypoints are read from disk and compiled here: an `import` of a stylesheet is stubbed out
// under vitest, and the assertion has to run against what a recipient's client receives.
const entrypointPath = (name: string) => fileURLToPath(new URL(`../../entrypoints/${name}.scss`, import.meta.url));

const compile = (name: string) => {
  const path = entrypointPath(name);
  return sass.compileString(readFileSync(path, "utf8"), {
    url: pathToFileURL(path),
    loadPaths: ["app/javascript"],
  }).css;
};

// Every declaration the stylesheet makes for exactly this selector, across the rules that list it.
const declarationsFor = (css: string, selector: string) =>
  [...css.matchAll(/([^{}]+)\{([^{}]*)\}/gu)]
    .filter(([, selectors = ""]) => selectors.split(",").some((listed) => listed.trim() === selector))
    .map(([, , declarations = ""]) => declarations.trim())
    .join(" ");

// Premailer inlines this stylesheet into style attributes, and mail clients read nothing else:
// they do not resolve custom properties, scale rem, load web fonts or understand cascade layers,
// and in dark mode they repaint the message themselves. So the bundle has to stay self-contained.
describe("email stylesheet", () => {
  const css = compile("email");

  it("does not follow the client's dark preference", () => {
    expect(css).not.toContain("prefers-color-scheme");
  });

  it("uses literal values instead of custom properties", () => {
    expect(css).not.toContain("var(");
    expect(css).not.toMatch(/(^|[\s{;])--[\w-]+\s*:/u);
  });

  it("sizes everything in px", () => {
    expect(css).not.toMatch(/\drem\b/u);
  });

  it("ships no web fonts", () => {
    expect(css).not.toContain("@font-face");
    expect(css).not.toContain("@import");
  });

  it("is not wrapped in cascade layers", () => {
    expect(css).not.toContain("@layer");
  });

  // Outlook on Windows frames a side that is `solid` at zero width, and `border: 0` over an earlier
  // `1px solid` inlines as exactly that. `none` clears the style.
  it("removes a border by style, not by width", () => {
    expect(css).not.toMatch(/border(-(top|right|bottom|left))?:\s*0\s*[;}]/u);
  });

  // A post sits on the seller's themed <body>, so it may not paint a surface of its own.
  it("leaves a post's background to the seller's theme", () => {
    expect(css).toMatch(/\.email\.post\s*\{[^}]*background-color:\s*inherit/u);
  });

  // The shared muted grey is under 4.5:1 on any seller background darker than #ececec.
  it("gives a post's table headers the seller's text colour", () => {
    expect(declarationsFor(css, ".email th")).toMatch(/(^|[;\s])color:\s*#6b6b66/u);
    expect(declarationsFor(css, ".email.post th")).toMatch(/(^|[;\s])color:\s*inherit/u);
  });

  // The inherited overflow-wrap cannot shrink a table cell, so one long word in a product's name
  // would push its row past the card and the phone's viewport.
  it("lets a product row break a long word in the name", () => {
    expect(declarationsFor(css, ".email table.product .product-info")).toMatch(/word-break:\s*break-word/u);
  });

  // A receipt's row label is the product's name. Without a floor under each column a long name
  // squeezes its price to a glyph per line, and one unbroken name pushes the table off a phone.
  it("holds both columns of a label/value table to a readable width", () => {
    const label = declarationsFor(css, ".email table.details th");
    expect(label).toMatch(/min-width:\s*96px/u);
    expect(label).toMatch(/word-break:\s*break-word/u);
    expect(declarationsFor(css, ".email table.details td")).toMatch(/min-width:\s*88px/u);
    // A fixed one-line label keeps its own width, so the receipt's header rows do not move.
    expect(declarationsFor(css, ".email table.details th.nowrap")).toMatch(/min-width:\s*0/u);
  });
});

describe("app stylesheet", () => {
  it("still ships the dark tokens", () => {
    expect(compile("design")).toContain("#242423");
  });
});
