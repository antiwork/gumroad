// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest";

import { LazySalesChart, loadSalesChart, warmSalesChart } from "$app/components/Analytics/loadChart";

const setOnLine = (value: boolean) => Object.defineProperty(navigator, "onLine", { configurable: true, value });

// The whole point of this module is what the Analytics route does NOT import. A future refactor
// adding `import { SalesChart } from ".../SalesChart"` back to index.tsx puts vendor-charts (323KB)
// back on the blocking path and silently undoes the fix, with no visible symptom on a warm cache
// and nothing else in the suite to catch it. These assertions are that guard.
describe("Analytics chart chunking", () => {
  it("keeps the chart out of the page's static imports", async () => {
    const source = (await import("$app/components/Analytics/index.tsx?raw")).default;

    expect(source).not.toMatch(/^import\s[^;]*\bSalesChart\b[^;]*from\s+"\$app\/components\/Analytics\/SalesChart"/mu);
    expect(source).toContain("LazySalesChart");
  });

  it("resolves the chart component itself, not the module namespace", async () => {
    // `lazy` needs `{ default: Component }`; handing it the module gives React an object with no
    // render and the chart fails at mount rather than at import, which is much harder to trace.
    const chartModule = await loadSalesChart();
    expect(typeof chartModule.SalesChart).toBe("function");
  });

  it("exposes the chart as a lazy component", () => {
    expect(LazySalesChart).toBeTypeOf("object");
    expect(LazySalesChart).toHaveProperty("$$typeof");
  });

  it("does not warm the chunk while offline, so a guaranteed failure never enters the module map", () => {
    setOnLine(false);
    const schedule = vi.spyOn(window, "setTimeout");
    try {
      const cancel = warmSalesChart();
      expect(schedule).not.toHaveBeenCalled();
      expect(() => cancel()).not.toThrow();
    } finally {
      vi.restoreAllMocks();
      setOnLine(true);
    }
  });

  it("prefers requestIdleCallback and cancels it, so the prefetch never competes with the page", () => {
    setOnLine(true);
    const cancelIdle = vi.fn();
    // happy-dom implements neither, which is also the Safari case the fallback below exists for.
    vi.stubGlobal("requestIdleCallback", vi.fn().mockReturnValue(1234));
    vi.stubGlobal("cancelIdleCallback", cancelIdle);
    try {
      warmSalesChart()();
      expect(window.requestIdleCallback).toHaveBeenCalled();
      expect(cancelIdle).toHaveBeenCalledWith(1234);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("falls back to a timeout where requestIdleCallback is missing, and that is cancellable too", () => {
    setOnLine(true);
    const clear = vi.spyOn(window, "clearTimeout");
    try {
      expect(window.requestIdleCallback).toBeUndefined();
      warmSalesChart()();
      expect(clear).toHaveBeenCalled();
    } finally {
      vi.restoreAllMocks();
    }
  });
});
