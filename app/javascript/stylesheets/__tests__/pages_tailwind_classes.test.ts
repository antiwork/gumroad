import { describe, expect, it } from "vitest";

import { pagesTailwindClasses } from "../../../../scripts/build_pages_tailwind.mjs";

// These utilities must be enumerated explicitly or Tailwind omits them from the generated stylesheet.
describe("pages Tailwind class list", () => {
  const has = (name: string) => pagesTailwindClasses.has(name);

  it("compiles the direction utility that consumes the gradient stops", () => {
    for (const direction of ["t", "tr", "r", "br", "b", "bl", "l", "tl"]) {
      // v4 spelling, and the v3 one pages authored against older docs still use.
      expect(has(`bg-linear-to-${direction}`)).toBe(true);
      expect(has(`bg-gradient-to-${direction}`)).toBe(true);
    }
    // A stop without a direction sets custom properties nothing reads.
    expect(has("from-red-500")).toBe(true);
  });

  it("compiles bg-clip-text so gradient headlines are visible", () => {
    expect(has("bg-clip-text")).toBe(true);
    expect(has("text-transparent")).toBe(true);
  });

  it("compiles margin-auto on every side", () => {
    for (const prefix of ["m", "mx", "my", "mt", "mr", "mb", "ml"]) {
      expect(has(`${prefix}-auto`)).toBe(true);
    }
  });

  it("keeps the numeric margin steps and does not invent negative auto", () => {
    expect(has("mx-4")).toBe(true);
    expect(has("-mt-4")).toBe(true);
    expect(has("-mx-auto")).toBe(false);
  });

  it("ships responsive and hover variants of the new utilities", () => {
    for (const name of ["lg:mx-auto", "md:bg-linear-to-r", "hover:bg-clip-text"]) {
      expect(has(name)).toBe(true);
    }
  });
});
