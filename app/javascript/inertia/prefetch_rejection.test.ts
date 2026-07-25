// @vitest-environment happy-dom
//
// Regression test for the bug where clicking a dashboard nav link did nothing at
// all: the click adopted a prefetch request that was still in flight, and when
// that prefetch later failed, the resulting promise rejection was never
// observed, so nothing ever navigated. The second click appeared to "work" only
// because by then the broken prefetch was no longer in the cache.
//
// The fix lives in patches/@inertiajs+core+2.3.13.patch. This test drives the
// real @inertiajs/core router, so it fails if a dependency bump ever drops the
// patch.
//
// The router reaches the network only through axios, so instead of mocking the
// module (Vitest leaves dependencies inside node_modules unmocked) we install a
// custom axios adapter on the shared axios instance the router itself imports.
import axios, { type AxiosAdapter } from "axios";
import { beforeEach, describe, expect, it, vi } from "vitest";

// Loading and initialising the real router costs seconds on a cold Vitest
// environment, so the default one-second waitFor budget is not enough to be
// reliable in CI. Every wait here is for something that happens in a
// microtask once the router is up, so a generous ceiling costs nothing.
const WAIT = { timeout: 5000 } as const;

const requests: string[] = [];
let pendingPrefetchReject: ((reason: Error) => void) | null = null;

const inertiaPage = (url: string) => ({
  component: "Page",
  props: {},
  url,
  version: "1",
  clearHistory: false,
  encryptHistory: false,
});

// Inertia marks its prefetch requests with the Purpose header, which is exactly
// how we tell the hover-triggered request apart from the click-triggered one.
// Axios normalises header casing inconsistently across versions, so check both.
const isPrefetch = (headers: Record<string, unknown> | undefined) =>
  headers?.Purpose === "prefetch" || headers?.purpose === "prefetch";

const adapter: AxiosAdapter = (config) => {
  const url = String(config.url);
  // config.url is absolute here (http://localhost:3000/products), so record the
  // pathname to keep the assertions readable.
  requests.push(`${isPrefetch(config.headers) ? "prefetch" : "visit"} ${new URL(url).pathname}`);

  if (isPrefetch(config.headers)) {
    // Never settle on its own: the test decides when this fails, which is what
    // makes the click adopt an *in-flight* prefetch rather than a cached one.
    return new Promise((_resolve, reject) => {
      pendingPrefetchReject = (reason) => reject(reason);
    });
  }

  return Promise.resolve({
    status: 200,
    statusText: "OK",
    data: JSON.stringify(inertiaPage(url)),
    headers: { "x-inertia": "true", "content-type": "application/json" },
    config,
  });
};

describe("inertia prefetch rejection", () => {
  beforeEach(() => {
    requests.length = 0;
    pendingPrefetchReject = null;
    axios.defaults.adapter = adapter;
  });

  it("still navigates when the click adopts a prefetch that then fails", async () => {
    const { router } = await import("@inertiajs/core");

    window.history.replaceState({}, "", "/dashboard");
    document.body.innerHTML = "<div id='app'></div>";

    router.init({
      initialPage: inertiaPage("/dashboard"),
      resolveComponent: () => Promise.resolve({}),
      swapComponent: () => Promise.resolve(),
    });

    // 1. Hover the sidebar link: a prefetch starts and stays in flight.
    router.prefetch("/products", { method: "get" }, { cacheFor: "1m" });
    await vi.waitFor(() => expect(requests).toContain("prefetch /products"), WAIT);

    // 2. Click that same link while the prefetch is still in flight, so the
    //    router adopts the prefetch instead of issuing its own request.
    router.visit("/products");

    // 3. The prefetch fails. Before the patch, this rejection was swallowed and
    //    the user's click was silently lost.
    pendingPrefetchReject?.(new Error("prefetch failed"));

    // 4. The click must still produce a real navigation request.
    await vi.waitFor(() => expect(requests).toContain("visit /products"), WAIT);
  });

  it("does not resurrect the abandoned page when the user navigates elsewhere first", async () => {
    const { router } = await import("@inertiajs/core");

    window.history.replaceState({}, "", "/dashboard");
    document.body.innerHTML = "<div id='app'></div>";

    router.init({
      initialPage: inertiaPage("/dashboard"),
      resolveComponent: () => Promise.resolve({}),
      swapComponent: () => Promise.resolve(),
    });

    // 1. Hover /products, then click it while its prefetch is still in flight,
    //    so this navigation adopts the prefetch.
    router.prefetch("/products", { method: "get" }, { cacheFor: "1m" });
    await vi.waitFor(() => expect(requests).toContain("prefetch /products"), WAIT);
    router.visit("/products");

    // 2. Nothing has rendered yet, so the user gives up and clicks a different
    //    link. This is an ordinary navigation with no prefetch to adopt.
    router.visit("/customers");
    await vi.waitFor(() => expect(requests).toContain("visit /customers"), WAIT);

    // 3. Only now does the abandoned prefetch fail. Recovering it here would
    //    send the user to a page they already left, so the failure must be
    //    dropped: no /products request may follow.
    pendingPrefetchReject?.(new Error("prefetch failed"));

    // The recovery path this guards against is synchronous once the rejection is
    // delivered, so a short settle is enough to prove it did not happen. Before
    // the fix the /products request appeared here within a single tick.
    await new Promise((resolve) => setTimeout(resolve, 250));
    expect(requests).not.toContain("visit /products");
  });

  it("does not resurrect the abandoned page after a client-side push to another page", async () => {
    const { router } = await import("@inertiajs/core");

    window.history.replaceState({}, "", "/dashboard");
    document.body.innerHTML = "<div id='app'></div>";

    router.init({
      initialPage: inertiaPage("/dashboard"),
      resolveComponent: () => Promise.resolve({}),
      swapComponent: () => Promise.resolve(),
    });

    router.prefetch("/products", { method: "get" }, { cacheFor: "1m" });
    await vi.waitFor(() => expect(requests).toContain("prefetch /products"), WAIT);
    router.visit("/products");

    // router.push() moves to another page entirely without going through
    // Router#visit, so it has to abandon the pending adoption as well.
    router.push({ component: "Page", url: "/customers", props: {} });
    await vi.waitFor(() => expect(window.location.pathname).toBe("/customers"), WAIT);

    pendingPrefetchReject?.(new Error("prefetch failed"));

    await new Promise((resolve) => setTimeout(resolve, 250));
    expect(requests).not.toContain("visit /products");
  });

  it("still navigates when only the props change on the current page while a prefetch is adopted", async () => {
    const { router } = await import("@inertiajs/core");

    window.history.replaceState({}, "", "/dashboard");
    document.body.innerHTML = "<div id='app'></div>";

    router.init({
      initialPage: inertiaPage("/dashboard"),
      resolveComponent: () => Promise.resolve({}),
      swapComponent: () => Promise.resolve(),
    });

    router.prefetch("/products", { method: "get" }, { cacheFor: "1m" });
    await vi.waitFor(() => expect(requests).toContain("prefetch /products"), WAIT);
    router.visit("/products");

    // A prop update on the page the user is still looking at is not a
    // navigation, so it must not cancel the click that is waiting on the
    // prefetch -- otherwise the original silent-click bug comes back.
    router.replaceProp("filter", "all");
    await new Promise((resolve) => setTimeout(resolve, 50));

    pendingPrefetchReject?.(new Error("prefetch failed"));

    await vi.waitFor(() => expect(requests).toContain("visit /products"), WAIT);
  });
});
