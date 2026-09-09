import { describe, expect, it } from "vitest";

// Both assertions guard what every Inertia page eagerly downloads. Neither failure mode has a
// visible symptom — the app works, it just ships more bytes — so nothing else in the suite would
// catch a refactor that undoes them.
describe("Inertia page bundle boundaries", () => {
  it("keeps colocated page tests out of the page glob", async () => {
    const source = (await import("$app/entrypoints/inertia.js?raw")).default;

    // A glob entry is a real module in the graph: `**/*.tsx` swept up the eight colocated
    // `*.test.tsx` files, and their vitest/chai/@testing-library imports were hoisted into the
    // vendor chunk every page loads, buyer product pages included.
    const globs = [...source.matchAll(/import\.meta\.glob\((.*?)\)/gu)].map(([, args = ""]) => args);
    expect(globs).not.toHaveLength(0);
    for (const args of globs) expect(args).toMatch(/!\(\*\.test\)|!.*\*\.test\./u);
  });

  it("pins Vite's dynamic-import helper to the vendor chunk", async () => {
    const config = (await import("../../../vite.config.ts?raw")).default;

    // Every chunk that lazy-loads imports this helper, so whichever chunk rollup parks it in
    // becomes a static dependency of all of them. Unpinned, it landed in vendor-pdf and put 171KB
    // of PDF.js on the blocking path for all 117 Inertia entries.
    expect(config).toMatch(/vite\/preload-helper[\s\S]{0,120}return "vendor"/u);
  });
});
