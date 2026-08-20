import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("$vendor/tiktok_pixel", () => ({ default: vi.fn() }));
vi.mock("$vendor/facebook_pixel", () => ({ default: vi.fn() }));
vi.mock("$vendor/google_analytics_4", () => ({ default: vi.fn() }));

const facebookTrack = vi.fn();
const tiktokTrack = vi.fn();
const googleTrack = vi.fn();

vi.mock("$app/data/facebook_pixel", () => ({
  trackProductEvent: (...args: unknown[]) => {
    facebookTrack(...args);
  },
  startTrackingForSeller: vi.fn(),
  trackProfilePageView: vi.fn(),
}));
vi.mock("$app/data/tiktok_pixel", () => ({
  trackProductEvent: (...args: unknown[]) => {
    tiktokTrack(...args);
  },
  startTrackingForSeller: vi.fn(),
}));
vi.mock("$app/data/google_analytics", () => ({
  trackProductEvent: (...args: unknown[]) => {
    googleTrack(...args);
  },
  startTrackingForSeller: vi.fn(),
  trackProfilePageView: vi.fn(),
}));

import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

const analytics = {
  google_analytics_id: "G-TEST",
  facebook_pixel_id: "1234567890",
  tiktok_pixel_id: "CTESTPIXELID1234567",
  free_sales: false,
};

const beginCheckout = {
  action: "begin_checkout" as const,
  seller_id: "seller-1",
  price: 9,
  products: [{ permalink: "demo", name: "Demo", quantity: 1, price: 9 }],
};

describe("trackProductEvent begin_checkout routing", () => {
  beforeEach(() => {
    facebookTrack.mockReset();
    tiktokTrack.mockReset();
    googleTrack.mockReset();
    startTrackingForSeller("seller-1", analytics);
  });

  it("forwards begin_checkout to TikTok and Google, not Facebook", () => {
    trackProductEvent("seller-1", beginCheckout);

    expect(googleTrack).toHaveBeenCalledWith(expect.anything(), beginCheckout);
    expect(tiktokTrack).toHaveBeenCalledWith(expect.anything(), beginCheckout);
    expect(facebookTrack).not.toHaveBeenCalled();
  });

  it("still forwards iwantthis to Facebook and TikTok", () => {
    const event = { action: "iwantthis" as const, permalink: "demo", product_name: "Demo" };
    trackProductEvent("seller-1", event);

    expect(facebookTrack).toHaveBeenCalledWith(expect.anything(), event);
    expect(tiktokTrack).toHaveBeenCalledWith(expect.anything(), event);
  });
});
