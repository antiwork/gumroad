import { lazy } from "react";

import { fetchWithOneRetry } from "$app/utils/lazy_chunk";

// Keep recharts/d3 out of Inertia's blocking route import; the page shell can paint while the chart loads.
const importSalesChart = () => import("$app/components/Analytics/SalesChart");

export const loadSalesChart = () => fetchWithOneRetry(importSalesChart);

export const LazySalesChart = lazy(async () => ({
  default: (await loadSalesChart()).SalesChart,
}));

// Warm the chart during idle time; if it fails, the lazy render path still owns the retry/error state.
export const warmSalesChart = () => {
  if (!navigator.onLine) return () => {};

  const warm = () => void loadSalesChart().catch(() => {});

  if (typeof window.requestIdleCallback === "function") {
    const handle = window.requestIdleCallback(warm, { timeout: 2000 });
    return () => window.cancelIdleCallback(handle);
  }

  const timer = window.setTimeout(warm, 500);
  return () => window.clearTimeout(timer);
};
