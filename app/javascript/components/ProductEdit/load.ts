import { lazy, useEffect, useState } from "react";

import { fetchWithOneRetry } from "$app/utils/lazy_chunk";

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
export const loadProductEditPage = () => fetchWithOneRetry(importProductEditPage);

// Start fetching the editor as soon as the Products list is done rendering. `requestIdleCallback`
// keeps it off the critical path so the list itself is never slowed down by the prefetch; browsers
// without it (Safari at the time of writing) fall back to a short timeout, which achieves the same
// thing a moment later. The hook returns whether product links must use a full-page navigation.
//
// Network failures can recover on the retry above, but evaluation failures stay cached and stale
// chunk URLs keep failing until the page gets the latest asset manifest. Until warm-up succeeds, a
// normal navigation is the safe choice: it gives the editor a fresh document instead of asking an
// Inertia visit to reuse a module request that is pending or has failed.
let productEditPageIsWarm = false;

export const useWarmProductEditPage = (load: () => Promise<unknown> = loadProductEditPage) => {
  const [requiresFullPageNavigation, setRequiresFullPageNavigation] = useState(!productEditPageIsWarm);

  useEffect(() => {
    // Do not put a guaranteed failure into the module map. If connectivity returns before the
    // seller clicks, the editor can then make its first request under normal conditions.
    if (!navigator.onLine) return;

    let active = true;
    const warm = () =>
      void load()
        .then(() => {
          productEditPageIsWarm = true;
          if (active) setRequiresFullPageNavigation(false);
        })
        .catch(() => {
          if (active) setRequiresFullPageNavigation(true);
        });

    if (typeof window.requestIdleCallback === "function") {
      const handle = window.requestIdleCallback(warm, { timeout: 2000 });
      return () => {
        active = false;
        window.cancelIdleCallback(handle);
      };
    }

    const timer = window.setTimeout(warm, 500);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [load]);

  return requiresFullPageNavigation;
};

export const LazyProductEditPage = lazy(async () => ({
  default: (await loadProductEditPage()).ProductEditPage,
}));
