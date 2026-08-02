// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import { CheckoutPreview } from "$app/components/CheckoutDashboard/CheckoutPreview";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("$app/components/Checkout/PaymentForm", () => ({ PaymentForm: () => null }));
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
