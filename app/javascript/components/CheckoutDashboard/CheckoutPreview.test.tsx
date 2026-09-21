// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import { CheckoutPreview } from "$app/components/CheckoutDashboard/CheckoutPreview";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// The card-element config the preview hands to the payment form, captured so the seller's Link
// setting can be asserted without a browser (PaymentForm is stubbed below).
const cardElementConfig = vi.hoisted<{ stripeLinkEnabled: boolean | null }>(() => ({ stripeLinkEnabled: null }));

vi.mock("$app/components/Checkout/PaymentForm", async () => {
  const { useState } = await import("$app/components/Checkout/payment");
  return {
    PaymentForm: () => {
      const [state] = useState();
      cardElementConfig.stripeLinkEnabled =
        state.checkoutPayment.integration === "card_element" ? state.checkoutPayment.stripe_link_enabled : null;
      return null;
    },
  };
});
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({ trackUserProductAction: vi.fn(), startTrackingForSeller: vi.fn() }));
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://gumroad.com/checkout",
}));

const renderPreview = (canGift: boolean) =>
  render(
    <CheckoutPreview
      cartItem={{ ...PLACEHOLDER_CART_ITEM, product: { ...PLACEHOLDER_CART_ITEM.product, can_gift: canGift } }}
    />,
  );

describe("CheckoutPreview gifting", () => {
  afterEach(cleanup);

  it("shows the gift section when the seller allows gifting", () => {
    const { queryByText } = renderPreview(true);
    expect(queryByText("Give as a gift?")).not.toBeNull();
  });

  it("hides the gift section when the seller has disabled gifting", () => {
    const { queryByText } = renderPreview(false);
    expect(queryByText("Give as a gift?")).toBeNull();
  });
});

describe("CheckoutPreview Link", () => {
  afterEach(cleanup);

  it("leaves Link on when the caller does not hand the seller's setting in", () => {
    render(<CheckoutPreview cartItem={PLACEHOLDER_CART_ITEM} />);
    expect(cardElementConfig.stripeLinkEnabled).toBe(true);
  });

  it("carries the seller's Link opt-out into the preview's card element", () => {
    render(<CheckoutPreview cartItem={PLACEHOLDER_CART_ITEM} stripeLinkEnabled={false} />);
    expect(cardElementConfig.stripeLinkEnabled).toBe(false);
  });
});
