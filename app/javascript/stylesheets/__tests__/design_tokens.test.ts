import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as sass from "sass";
import { describe, expect, it } from "vitest";

import { getContrastRatio } from "$app/utils/color";

// Read from disk and compiled here: an `import` of a stylesheet is stubbed out under vitest.
const path = (relative: string) => fileURLToPath(new URL(relative, import.meta.url));
const designPath = path("../../entrypoints/design.scss");
const design = sass.compileString(readFileSync(designPath, "utf8"), {
  url: pathToFileURL(designPath),
  loadPaths: ["app/javascript"],
}).css;
const tailwind = readFileSync(path("../tailwind.css"), "utf8");

// The dark tokens are the declarations inside the prefers-color-scheme block.
const darkStart = design.indexOf("prefers-color-scheme: dark");
const light = design.slice(0, darkStart);
const dark = design.slice(darkStart);
const token = (css: string, name: string) => {
  const value = new RegExp(`--${name}:\\s*([^;]+);`, "u").exec(css)?.[1];
  if (value === undefined) throw new Error(`--${name} is not set`);
  return value.trim();
};

const channels = (hex: string) => [1, 3, 5].map((start) => parseInt(hex.slice(start, start + 2), 16));
// The opaque colour a translucent one becomes on a surface.
const over = (hex: string, alpha: number, surface: string) =>
  `#${channels(hex)
    .map((channel, index) => Math.round(channel * alpha + (channels(surface)[index] ?? 0) * (1 - alpha)))
    .map((channel) => channel.toString(16).padStart(2, "0"))
    .join("")}`;

const schemes = [
  { name: "light", css: light, text: "#000000", surface: "#ffffff", page: "#f4f4f0" },
  { name: "dark", css: dark, text: "#dddddd", surface: "#000000", page: "#242423" },
];

// The field border is this formula over --border-alpha (see the `@theme inline` block).
const controlFormula =
  /--color-control:\s*rgb\(var\(--color\) \/ max\(var\(--border-alpha\) \+ ([\d.]+), ([\d.]+)\)\)/u.exec(tailwind);
const controlAlpha = (css: string) => {
  if (!controlFormula) throw new Error("--color-control does not have the expected formula");
  return Math.max(Number(token(css, "border-alpha")) + Number(controlFormula[1]), Number(controlFormula[2]));
};

describe("design tokens", () => {
  it("draws decorative borders as a hairline of the text colour, not solid black", () => {
    expect(Number(token(light, "border-alpha"))).toBeLessThanOrEqual(0.15);
    expect(tailwind).toContain("--color-border: rgb(var(--color) / var(--border-alpha));");
  });

  // A bare `border` utility sets width and style only; without this it falls back to currentColor.
  it("gives a border with no colour utility the hairline colour", () => {
    expect(design).toMatch(
      /border-width:\s*0;\s*border-color:\s*rgb\(var\(--parent-color\)\s*\/\s*var\(--border-alpha\)\)/u,
    );
  });

  // WCAG 1.4.11: a field's border is its only edge, inside against its fill and outside against the page.
  it.each(schemes)("keeps form field borders at 3:1 in $name mode", ({ css, text, surface, page }) => {
    const border = over(text, controlAlpha(css), surface);

    expect(getContrastRatio(border, surface)).toBeGreaterThanOrEqual(3);
    expect(getContrastRatio(border, page)).toBeGreaterThanOrEqual(3);
  });

  it("points native form fields at the field border", () => {
    expect(tailwind).toMatch(
      /input,\s*textarea,\s*select\s*\{\s*--color-border:\s*--theme\(--color-control inline\);/u,
    );
  });

  // Stripe's iframe cannot use the formula, so its border alpha is a second copy of the result.
  it.each(schemes)("gives Stripe fields the same border as native fields in $name mode", ({ css }) => {
    expect(Number(token(css, "neutral-border-alpha"))).toBeCloseTo(controlAlpha(css), 5);
  });

  // WCAG 1.4.3: muted text is the text colour at --gray-3, on cards, on the page and on hover tints.
  it.each(schemes)("keeps muted text at 4.5:1 in $name mode", ({ text, surface, page }) => {
    const alpha = Number(token(design, "gray-3"));
    const tint = (base: string) => over(text, Number(token(design, "gray-1")), base);

    for (const background of [surface, page, tint(surface), tint(page)]) {
      expect(getContrastRatio(over(text, alpha, background), background)).toBeGreaterThanOrEqual(4.5);
    }
  });

  // WCAG 1.4.11: a focus ring in the accent pink is 2:1 on white. The text colour clears 3:1 everywhere.
  it("draws focus and selection rings in the text colour unless a page sets its own", () => {
    expect(tailwind).toContain("--color-indicator: rgb(var(--indicator, var(--color)));");
    expect(tailwind).toMatch(/:where\(:focus-visible\)\s*\{\s*outline:\s*2px solid var\(--color-foreground\);/u);
  });

  it("has no hard offset shadow and no hover lift by default", () => {
    for (const name of ["shadow", "shadow-lg"]) {
      const value = token(tailwind, name);
      expect(value).not.toContain("currentColor");
      // Every layer starts `0 <y> <blur>`: no sideways offset, and a blur.
      for (const layer of value.split(/,\s*(?=\d)/u)) expect(layer).toMatch(/^0 \d+px [1-9]\d*px /u);
    }
    expect(token(tailwind, "button-hover-offset")).toBe("0rem");
  });

  it("rounds controls at 8px", () => {
    expect(token(tailwind, "radius")).toBe("0.5rem");
  });
});
