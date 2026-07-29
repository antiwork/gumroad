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
export const loadProductEditPage = async () => {
  const module = await fetchWithOneRetry(importProductEditPage);
  // The chunk is here, so whatever went wrong before is over. Forget any recovery reload
  // (see below), otherwise a failure much later in the same tab would be shown as an error straight
  // away instead of getting the one reload that usually fixes it.
  clearRecoveryReload();
  return module;
};

// A dynamic import that has failed is remembered as failed. The browser keeps one entry per module
// URL, and a fetch that failed leaves that entry holding the error, so every later import of the
// same URL re-throws it immediately without going back to the network. Nothing inside the page can
// clear that entry — only loading a fresh document can.
//
// That is a problem here because the Products list warms the editor's chunk in the background. If
// that warm-up happens to run during a bad moment on the network, the seller's click a minute later
// fails instantly even though their connection has recovered, and the retry above cannot help
// either: both attempts read the same poisoned entry. Left alone, the seller sees the failure
// screen and can only get out of it by pressing "Try again", which reloads.
//
// So do that reload for them, once. The first failure gets a silent reload — which starts a new
// document with an empty module map and therefore a real network request — and only a failure that
// survives the reload is shown as an error. The "once" is what stops a genuine outage from turning
// into a reload loop; it is remembered in session storage because the counter has to outlive the
// document it is protecting.
const RECOVERY_RELOAD_KEY = "product-edit-recovery-reload";

// Returns whether a reload was started, so the caller knows whether to expect the page to go away
// or to show the seller an error instead.
export const attemptRecoveryReload = (): boolean => {
  // Reloading while the browser knows it is offline would replace a recoverable error screen with
  // the browser's own "no internet" page, which is strictly worse: no way back to the products list
  // and no way to try again.
  if (!navigator.onLine) return false;

  try {
    if (sessionStorage.getItem(RECOVERY_RELOAD_KEY) !== null) return false;
    sessionStorage.setItem(RECOVERY_RELOAD_KEY, "1");
  } catch {
    // Session storage can be unavailable (Safari in private browsing, storage disabled by policy).
    // Without somewhere to remember the attempt there is no way to tell a first failure from a
    // hundredth, so don't reload at all rather than risk looping.
    return false;
  }

  location.reload();
  return true;
};

const clearRecoveryReload = () => {
  try {
    sessionStorage.removeItem(RECOVERY_RELOAD_KEY);
  } catch {
    // Nothing to clean up if storage is unavailable — the attempt was never recorded.
  }
};

// Start fetching the editor as soon as the Products list is done rendering. `requestIdleCallback`
// keeps it off the critical path so the list itself is never slowed down by the prefetch; browsers
// without it (Safari at the time of writing) fall back to a short timeout, which achieves the same
// thing a moment later.
export const useWarmProductEditPage = () => {
  useEffect(() => {
    // A prefetch that fails is not a problem worth reporting — nobody has asked for the editor yet,
    // and the click that does ask will try again. Swallow the rejection so it does not surface as an
    // unhandled promise error in the console or in error reporting.
    //
    // Skip it entirely when the browser already knows it is offline. A prefetch is a convenience, so
    // there is nothing to gain by attempting one that cannot succeed, and something to lose: the
    // failed attempt leaves the browser holding a rejected entry for this chunk that no later import
    // in this document can get past.
    const warm = () => {
      if (!navigator.onLine) return;
      void loadProductEditPage().catch(() => {});
    };

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
