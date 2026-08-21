// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("$vendor/tiktok_pixel", () => ({ default: vi.fn() }));
vi.mock("$vendor/facebook_pixel", () => ({ default: vi.fn() }));
vi.mock("$vendor/google_analytics_4", () => ({ default: vi.fn() }));

import { trackProductEvent } from "$app/data/tiktok_pixel";
import type { AnalyticsConfig } from "$app/utils/user_analytics";

const PIXEL_ID = "CTESTPIXELID1234567";

const config: AnalyticsConfig = {
  id: "seller-1",
  facebookPixelId: null,
  googleAnalyticsId: null,
  tiktokPixelId: PIXEL_ID,
  trackFreeSales: false,
};

function enablePixel() {
  document.head.innerHTML = '<meta property="gr:tiktok_pixel:enabled" content="true">';
}

function stubTtq() {
  const track = vi.fn();
  const page = vi.fn();
  const instance = vi.fn(() => ({ track, page }));
  vi.stubGlobal("ttq", { load: vi.fn(), page: vi.fn(), track: vi.fn(), instance });
  return { track, instance };
}

describe("TikTok trackProductEvent", () => {
  beforeEach(() => {
    document.head.innerHTML = "";
    vi.unstubAllGlobals();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("maps begin_checkout to InitiateCheckout with cart contents", () => {
    enablePixel();
    const { track, instance } = stubTtq();

    trackProductEvent(config, {
      action: "begin_checkout",
      seller_id: "seller-1",
      price: 12.5,
      products: [
        { permalink: "demo", name: "Demo", quantity: 2, price: 5 },
        { permalink: "pack", name: "Pack", quantity: 1, price: 2.5 },
      ],
    });

    expect(instance).toHaveBeenCalledWith(PIXEL_ID);
    expect(track).toHaveBeenCalledWith("InitiateCheckout", {
      contents: [
        { content_id: "demo", content_type: "product", quantity: 2, price: 5 },
        { content_id: "pack", content_type: "product", quantity: 1, price: 2.5 },
      ],
      value: 12.5,
      currency: "USD",
      content_type: "product",
    });
  });

  it("does not fire InitiateCheckout for a free checkout unless trackFreeSales", () => {
    enablePixel();
    const { track } = stubTtq();

    trackProductEvent(config, {
      action: "begin_checkout",
      seller_id: "seller-1",
      price: 0,
      products: [{ permalink: "free", name: "Free", quantity: 1, price: 0 }],
    });
    expect(track).not.toHaveBeenCalled();

    trackProductEvent(
      { ...config, trackFreeSales: true },
      {
        action: "begin_checkout",
        seller_id: "seller-1",
        price: 0,
        products: [{ permalink: "free", name: "Free", quantity: 1, price: 0 }],
      },
    );
    expect(track).toHaveBeenCalledWith("InitiateCheckout", expect.objectContaining({ value: 0 }));
  });

  it("still maps iwantthis to AddToCart", () => {
    enablePixel();
    const { track } = stubTtq();

    trackProductEvent(config, { action: "iwantthis", permalink: "demo", product_name: "Demo" });

    expect(track).toHaveBeenCalledWith("AddToCart", { content_id: "demo", content_type: "product" });
  });

  it("does not track when the pixel meta tag is off", () => {
    document.head.innerHTML = '<meta property="gr:tiktok_pixel:enabled" content="false">';
    const { track } = stubTtq();

    trackProductEvent(config, {
      action: "begin_checkout",
      seller_id: "seller-1",
      price: 10,
      products: [{ permalink: "demo", name: "Demo", quantity: 1, price: 10 }],
    });

    expect(track).not.toHaveBeenCalled();
  });
});
