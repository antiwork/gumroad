import { describe, expect, it } from "vitest";
import { manualChunks } from "../../../config/vite/manual-chunks";

// No visible failure if these regress — the app still works, just ships extra bytes.
describe("Inertia page bundle boundaries", () => {
  it("keeps colocated page tests out of the page glob", async () => {
    const source = (await import("$app/entrypoints/inertia.js?raw")).default.replace(/\/\/[^\n]*/gu, "");
    const globs = [...source.matchAll(/import\.meta\.glob\(\[([^\]]+)\]\)/gu)].map(([, args = ""]) => args);
    expect(globs).not.toHaveLength(0);
    for (const args of globs) expect(args).toMatch(/!\.\.\/pages\/\*\*\/\*\.test\./u);

    const included = Object.keys(import.meta.glob(["../pages/**/*.tsx", "!../pages/**/*.test.tsx"])) as string[];
    const unfiltered = Object.keys(import.meta.glob("../pages/**/*.tsx")) as string[];
    expect(unfiltered.some((key) => key.endsWith(".test.tsx"))).toBe(true);
    expect(included.some((key) => key.includes(".test."))).toBe(false);
  });

  it("pins Vite's dynamic-import helper to the vendor chunk", async () => {
    const configSource = (await import("../../../vite.config.ts?raw")).default.replace(/\/\/[^\n]*/gu, "");
    expect(configSource).toMatch(/from\s+["']\.\/config\/vite\/manual-chunks["']/u);
    expect(configSource).toMatch(/manualChunks,/u);

    expect(manualChunks("vite/preload-helper")).toBe("vendor");
    expect(manualChunks("/node_modules/vite/dist/client/preload-helper.js")).toBe("vendor");
    expect(manualChunks("/node_modules/pdfjs-dist/build/pdf.js")).toBe("vendor-pdf");
  });
});
