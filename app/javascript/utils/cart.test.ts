// @vitest-environment node
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cartItemsCountSrc, hasCartItems } from "$app/utils/cart";

describe("hasCartItems", () => {
  it("is false when the count could not be read", () => {
    expect(hasCartItems("not-available")).toBe(false);
    expect(hasCartItems(null)).toBe(false);
  });

  it("is false for an empty cart and true above zero", () => {
    expect(hasCartItems(0)).toBe(false);
    expect(hasCartItems(2)).toBe(true);
  });
});

describe("cartItemsCountSrc", () => {
  const setHost = (host: string) => vi.stubGlobal("window", { location: { host, href: `http://${host}/` } });

  beforeEach(() => {
    vi.stubGlobal("Routes", {
      cart_items_count_path: () => "/cart_items_count",
      cart_items_count_url: () => "https://gumroad.com/cart_items_count",
    });
  });

  afterEach(() => vi.unstubAllGlobals());

  it("is same-origin on the root domain and on its storefront subdomains", () => {
    for (const host of ["gumroad.com", "stanleynumber2.gumroad.com"]) {
      setHost(host);
      expect(cartItemsCountSrc()).toBe("/cart_items_count");
    }
  });

  it("stays on the root domain on a custom domain, which does not share the cart cookie", () => {
    setHost("shop.s2madeit.com");
    expect(cartItemsCountSrc()).toBe("https://gumroad.com/cart_items_count");
  });
});

describe("loadCartItemsCount", () => {
  const routes = {
    cart_items_count_path: () => "/cart_items_count",
    cart_items_count_url: () => "https://gumroad.com/cart_items_count",
  };

  const stubWindow = (host: string, onMessage?: (listener: (evt: MessageEvent) => void) => void) => {
    vi.stubGlobal("window", {
      location: { host, href: `https://${host}/` },
      addEventListener: (type: string, listener: (evt: MessageEvent) => void) => {
        if (type === "message" && onMessage) onMessage(listener);
      },
      removeEventListener: vi.fn(),
    });
  };

  afterEach(() => vi.unstubAllGlobals());

  const load = async (host: string, fetchImpl?: unknown, onMessage?: (l: (evt: MessageEvent) => void) => void) => {
    vi.resetModules();
    vi.stubGlobal("Routes", routes);
    if (fetchImpl) vi.stubGlobal("fetch", fetchImpl);
    stubWindow(host, onMessage);

    const { loadCartItemsCount } = await import("$app/utils/cart");
    return new Promise((resolve) => loadCartItemsCount(routes.cart_items_count_url(), resolve));
  };

  it("reads a same-origin count with the page's own request", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: true, json: async () => ({ cart_items_count: 3 }) }));

    await expect(load("stanleynumber2.gumroad.com", fetchImpl)).resolves.toBe(3);
    expect(fetchImpl).toHaveBeenCalledWith(
      "/cart_items_count",
      expect.objectContaining({ headers: { Accept: "application/json" } }),
    );
  });

  it("reports an unreadable count when the same-origin request fails", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("offline");
    });

    await expect(load("stanleynumber2.gumroad.com", fetchImpl)).resolves.toBe("not-available");
  });

  it("falls back to the root-domain frame on a custom domain", async () => {
    const iframe = { style: {} as Record<string, string>, contentWindow: {}, remove: vi.fn(), src: "" };
    const appended: unknown[] = [];
    let handler: ((evt: MessageEvent) => void) | undefined;
    vi.stubGlobal("document", {
      createElement: () => iframe,
      body: { appendChild: (el: unknown) => appended.push(el) },
    });

    const count = await load("shop.s2madeit.com", undefined, (listener) => (handler = listener));

    expect(appended).toEqual([iframe]);
    expect(iframe.src).toBe("https://gumroad.com/cart_items_count");

    handler?.({
      source: iframe.contentWindow,
      origin: "https://gumroad.com",
      data: { type: "cart-items-count", cartItemsCount: 4 },
    } as unknown as MessageEvent);

    await expect(count).resolves.toBe(4);
  });
});
