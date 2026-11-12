// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { trackProductEvent } from "./facebook_pixel";

const config = {
  id: "seller-1",
  googleAnalyticsId: null,
  facebookPixelId: "1234567890",
  tiktokPixelId: null,
  trackFreeSales: false,
};

const purchase = {
  action: "purchased" as const,
  permalink: "demo",
  purchase_external_id: "purchase-external-id",
  seller_id: "seller-1",
  product_name: "Demo",
  value: 2000,
  valueIsSingleUnit: false,
  currency: "usd",
  quantity: 1,
  tax: "0",
};

describe("trackProductEvent", () => {
  let fbq: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    document.head.innerHTML = '<meta property="gr:fb_pixel:enabled" content="true">';
    fbq = vi.fn();
    vi.stubGlobal("fbq", fbq);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.head.innerHTML = "";
  });

  it("sends the purchase's external ID as the event ID of the Purchase event", () => {
    trackProductEvent(config, purchase);

    expect(fbq).toHaveBeenCalledExactlyOnceWith(
      "trackSingle",
      "1234567890",
      "Purchase",
      { content_ids: ["demo"], content_type: "product", value: 20, currency: "usd" },
      { eventID: "purchase-external-id" },
    );
  });

  it("sends no event ID with the other events", () => {
    trackProductEvent(config, { action: "viewed", permalink: "demo", product_name: "Demo" });
    trackProductEvent(config, { action: "iwantthis", permalink: "demo", product_name: "Demo" });

    expect(fbq.mock.calls).toEqual([
      ["trackSingle", "1234567890", "ViewContent", { content_ids: ["demo"], content_type: "product" }],
      ["trackSingle", "1234567890", "InitiateCheckout", { content_ids: ["demo"], content_type: "product" }],
    ]);
  });
});
