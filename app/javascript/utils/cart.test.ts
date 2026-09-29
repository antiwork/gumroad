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

  const load = async (
    host: string,
    fetchImpl: (url: string, init?: { cache?: string; headers?: Record<string, string> }) => Promise<unknown>,
  ) => {
    vi.resetModules();
    vi.stubGlobal("Routes", routes);
    vi.stubGlobal("fetch", fetchImpl);
    vi.stubGlobal("window", { location: { host, href: `https://${host}/` } });

    const { loadCartItemsCount } = await import("$app/utils/cart");
    return new Promise((resolve) => loadCartItemsCount(routes.cart_items_count_url(), resolve));
  };

  afterEach(() => vi.unstubAllGlobals());

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
});
