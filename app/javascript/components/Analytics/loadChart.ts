import { lazy } from "react";

import { fetchWithOneRetry } from "$app/utils/lazy_chunk";

// Keep recharts/d3 out of Inertia's blocking route import; the page shell can paint while the chart loads.
const importSalesChart = () => import("$app/components/Analytics/SalesChart");

export const loadSalesChart = () => fetchWithOneRetry(importSalesChart);

export const LazySalesChart = lazy(async () => ({
  default: (await loadSalesChart()).SalesChart,
}));

// Warm the chart during idle time; if it fails, the lazy render path still owns the retry/error state.
const IDLE_WARM_TIMEOUT_MS = 2000;
const FALLBACK_WARM_DELAY_MS = 500;

export const warmSalesChart = () => {
  if (!navigator.onLine) return () => {};

  const warm = () => void loadSalesChart().catch(() => {});

  if (typeof window.requestIdleCallback === "function") {
    const handle = window.requestIdleCallback(warm, { timeout: IDLE_WARM_TIMEOUT_MS });
    return () => window.cancelIdleCallback(handle);
  }

  const timer = window.setTimeout(warm, FALLBACK_WARM_DELAY_MS);
  return () => window.clearTimeout(timer);
};
