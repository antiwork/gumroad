import { lazy, useEffect } from "react";

// The product editor is by far the largest page in the dashboard: it carries the rich text editor,
// the file uploader, and the live product preview. Two things follow from that, and this module
// owns both.
//
// 1. The editor is loaded as its own chunk (`lazy` below) so the Products/Edit page can render
//    something — a skeleton of the editor — the moment the server responds, instead of leaving the
//    seller looking at the previous page while a few hundred kilobytes of JavaScript arrive. That
//    delay is why sellers reported that clicking a product "does nothing" (gumroad-private#1469).
// 2. The chunk is fetched ahead of time from the Products list (`useWarmProductEditPage`), so by
//    the time a seller clicks a product the code is usually already in memory and the editor
//    appears immediately, with no skeleton at all.
const importProductEditPage = () => import("$app/components/server-components/ProductEditPage");

// Fetch the editor's code without rendering it. Safe to call repeatedly: the browser and the module
// registry both cache the result, so only the first call costs a request.
export const loadProductEditPage = importProductEditPage;

// Start fetching the editor as soon as the Products list is done rendering. `requestIdleCallback`
// keeps it off the critical path so the list itself is never slowed down by the prefetch; browsers
// without it (Safari at the time of writing) fall back to a short timeout, which achieves the same
// thing a moment later.
export const useWarmProductEditPage = () => {
  useEffect(() => {
    const warm = () => void loadProductEditPage();

    if (typeof window.requestIdleCallback === "function") {
      const handle = window.requestIdleCallback(warm, { timeout: 2000 });
      return () => window.cancelIdleCallback(handle);
    }

    const timer = window.setTimeout(warm, 500);
    return () => window.clearTimeout(timer);
  }, []);
};

export const LazyProductEditPage = lazy(async () => ({ default: (await importProductEditPage()).ProductEditPage }));
