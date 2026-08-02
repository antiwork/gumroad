import { lazy } from "react";

import { fetchWithOneRetry } from "$app/utils/lazy_chunk";

// The sales chart is the only thing on the Analytics page that needs `vendor-charts` (recharts +
// d3), which is 323KB of the 365KB the page pulls beyond what a typical previous dashboard page has
// already cached. Inertia does not swap the DOM until the route component's import settles, so on a
// cold cache that whole download sat between the click and any paint — the seller kept looking at
// the page they had just left, for seconds, while the server had already answered in ~40ms
// (gumroad-private#1735). Splitting the chart out takes it off that blocking path: the page shell,
// stats, tables and date picker render immediately and the chart area fills in behind a skeleton.
//
// This is the same fix, for the same complaint, as the product editor's (gumroad-private#1469) —
// see ProductEdit/load.ts, which shares the retry helper.
const importSalesChart = () => import("$app/components/Analytics/SalesChart");

export const loadSalesChart = () => fetchWithOneRetry(importSalesChart);

export const LazySalesChart = lazy(async () => ({
  default: (await loadSalesChart()).SalesChart,
}));

// Start fetching the chart as soon as the browser is idle, so the download overlaps the three
// analytics data requests the page fires on mount rather than waiting for them. By the time the
// data arrives the chart is normally already in memory and no skeleton is ever seen. Browsers
// without `requestIdleCallback` (Safari at the time of writing) fall back to a short timeout.
//
// Failures are swallowed: this is only a head start. If it does not land, `LazySalesChart` makes
// the request itself when the data resolves, and the boundary below it owns that error.
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
