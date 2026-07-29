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

// Fetching a separate chunk means a network request, and network requests fail: a dropped
// connection, a flaky proxy, or a CDN edge that briefly serves an error. A single failed request
// must not cost the seller their editor, so retry once after a short pause before giving up. One
// retry covers the momentary blips, which are the overwhelming majority; anything still failing
// after that is a real outage and the caller shows a recoverable error instead (see
// ProductEditBoundary).
//
// The retry has to wrap the promise React is given rather than live in the component, because
// `React.lazy` remembers a rejected import forever — once its promise rejects, every later render
// re-throws the same error and the loader is never called again. So the promise React sees must be
// the one that has already done its retrying.
const RETRY_DELAY_MS = 500;

export const fetchWithOneRetry = async <T>(fetch: () => Promise<T>, delayMs = RETRY_DELAY_MS): Promise<T> => {
  try {
    return await fetch();
  } catch (firstError) {
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    try {
      return await fetch();
    } catch {
      // Report the original failure: it is the one that happened under normal conditions, so it
      // describes the problem better than a retry that was always likely to fail too.
      throw firstError;
    }
  }
};

// Fetch the editor's code without rendering it. Safe to call repeatedly: the browser and the module
// registry both cache the result, so only the first call costs a request.
export const loadProductEditPage = () => fetchWithOneRetry(importProductEditPage);

// Start fetching the editor as soon as the Products list is done rendering. `requestIdleCallback`
// keeps it off the critical path so the list itself is never slowed down by the prefetch; browsers
// without it (Safari at the time of writing) fall back to a short timeout, which achieves the same
// thing a moment later.
export const useWarmProductEditPage = () => {
  useEffect(() => {
    // A prefetch that fails is not a problem worth reporting — nobody has asked for the editor yet,
    // and the click that does ask will try again. Swallow the rejection so it does not surface as an
    // unhandled promise error in the console or in error reporting.
    const warm = () => void loadProductEditPage().catch(() => {});

    if (typeof window.requestIdleCallback === "function") {
      const handle = window.requestIdleCallback(warm, { timeout: 2000 });
      return () => window.cancelIdleCallback(handle);
    }

    const timer = window.setTimeout(warm, 500);
    return () => window.clearTimeout(timer);
  }, []);
};

export const LazyProductEditPage = lazy(async () => ({
  default: (await loadProductEditPage()).ProductEditPage,
}));
