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

const stubLocation = (host: string) =>
  vi.stubGlobal("window", {
    location: { host, href: `https://${host}/`, origin: `https://${host}` },
    addEventListener: vi.fn(),
  });

const stubRoutes = (url: string) =>
  vi.stubGlobal("Routes", { cart_items_count_path: () => "/cart_items_count", cart_items_count_url: () => url });

describe("cartItemsCountSrc", () => {
  beforeEach(() => stubRoutes("https://gumroad.com/cart_items_count"));

  afterEach(() => vi.unstubAllGlobals());

  it("is same-origin on the root domain and on its storefront subdomains", () => {
    for (const host of ["gumroad.com", "stanleynumber2.gumroad.com"]) {
      stubLocation(host);
      expect(cartItemsCountSrc("gumroad.com")).toBe("/cart_items_count");
    }
  });

  it("stays on the root domain on a custom domain, which does not share the cart cookie", () => {
    stubLocation("shop.s2madeit.com");
    expect(cartItemsCountSrc("gumroad.com")).toBe("https://gumroad.com/cart_items_count");
  });

  describe("when the app domain differs from the root domain", () => {
    const appUrl = "http://app.test.gumroad.com:31337/cart_items_count";

    beforeEach(() => stubRoutes(appUrl));

    it("is same-origin on the root domain and on its storefront subdomains", () => {
      for (const host of ["test.gumroad.com:31337", "seller.test.gumroad.com:31337"]) {
        stubLocation(host);
        expect(cartItemsCountSrc("test.gumroad.com:31337")).toBe("/cart_items_count");
      }
    });

    it("stays on the app domain for lookalike hosts, other ports, and custom domains", () => {
      for (const host of [
        "evil-test.gumroad.com:31337",
        "seller.test.gumroad.com:31338",
        "test.gumroad.com.evil.example:31337",
        "shop.example.com",
      ]) {
        stubLocation(host);
        expect(cartItemsCountSrc("test.gumroad.com:31337")).toBe(appUrl);
      }
    });
  });
});

describe("loadCartItemsCount", () => {
  type FetchImpl = (url: string, init?: { cache?: string; headers?: Record<string, string> }) => Promise<unknown>;

  const setup = (host: string, url: string, fetchImpl: FetchImpl) => {
    vi.resetModules();
    stubRoutes(url);
    vi.stubGlobal("fetch", fetchImpl);
    stubLocation(host);
    return import("$app/utils/cart");
  };

  const load = async (
    host: string,
    fetchImpl: FetchImpl,
    { rootDomain = "gumroad.com", url = "https://gumroad.com/cart_items_count" } = {},
  ) => {
    const cart = await setup(host, url, fetchImpl);
    return new Promise((resolve) => cart.loadCartItemsCount(cart.cartItemsCountSrc(rootDomain), resolve));
  };

  afterEach(() => vi.unstubAllGlobals());

  it("reads a same-origin count with the page's own request", async () => {
    const fetchImpl = vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve({ cart_items_count: 3 }) }));

    await expect(load("stanleynumber2.gumroad.com", fetchImpl)).resolves.toBe(3);
    expect(fetchImpl).toHaveBeenCalledWith(
      "/cart_items_count",
      expect.objectContaining({ headers: { Accept: "application/json" } }),
    );
  });

  it("reports an unreadable count when the same-origin request fails", async () => {
    const fetchImpl = vi.fn(() => Promise.reject(new Error("offline")));

    await expect(load("stanleynumber2.gumroad.com", fetchImpl)).resolves.toBe("not-available");
  });

  it("reads a storefront subdomain's own count when the app domain differs from the root domain", async () => {
    const counts: Record<string, number> = {
      "/cart_items_count": 2,
      "http://app.test.gumroad.com:31337/cart_items_count": 7,
    };
    const fetchImpl = vi.fn((src: string) =>
      Promise.resolve({ ok: true, json: () => Promise.resolve({ cart_items_count: counts[src] }) }),
    );

    await expect(
      load("seller.test.gumroad.com:31337", fetchImpl, {
        rootDomain: "test.gumroad.com:31337",
        url: "http://app.test.gumroad.com:31337/cart_items_count",
      }),
    ).resolves.toBe(2);
  });

  it("reads a custom domain's count from a root-domain frame instead of fetching it", async () => {
    const fetchImpl = vi.fn();
    const iframe = { style: { display: "" }, src: "", remove: vi.fn() };
    const appendChild = vi.fn();
    vi.stubGlobal("document", { createElement: () => iframe, body: { appendChild } });
    const cart = await setup("shop.s2madeit.com", "https://gumroad.com/cart_items_count", fetchImpl);

    cart.loadCartItemsCount(cart.cartItemsCountSrc("gumroad.com"), vi.fn());

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(appendChild).toHaveBeenCalledWith(iframe);
    expect(iframe.src).toBe("https://gumroad.com/cart_items_count");
  });
});
