// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PLACEHOLDER_CART_ITEM } from "$app/utils/cart";

import FormPage, { FormPageProps } from "$app/components/CheckoutDashboard/FormPage";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

vi.mock("@inertiajs/react", () => ({
  useForm: <T,>(initial: T) => {
    const [data, setData] = React.useState(initial);
    return {
      data,
      setData: (key: keyof T, value: T[keyof T]) => setData((prev) => ({ ...prev, [key]: value })),
      processing: false,
      errors: {},
      put: vi.fn(),
      post: vi.fn(),
    };
  },
}));

vi.mock("$app/components/Checkout/PaymentForm", () => ({ PaymentForm: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({ trackUserProductAction: vi.fn(), startTrackingForSeller: vi.fn() }));
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => null }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://gumroad.com/checkout",
}));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { checkout_form: { update: true } } }),
}));
vi.mock("$app/components/CheckoutDashboard/PayPalConnectSection", () => ({ default: () => null }));

const props = (giftingDisabled: boolean): FormPageProps => ({
  pages: [],
  user: {
    display_offer_code_field: false,
    recommendation_type: "no_recommendations",
    tipping_enabled: false,
    ach_payments_enabled: false,
    gifting_disabled: giftingDisabled,
  },
  cart_item: PLACEHOLDER_CART_ITEM,
  card_product: null,
  custom_fields: [],
  products: [],
  paypal_connect: {
    email: null,
    charge_processor_merchant_id: null,
    charge_processor_verified: false,
    needs_email_confirmation: false,
    unsupported_countries: [],
    show_paypal_connect: false,
    allow_paypal_connect: false,
    paypal_disconnect_allowed: false,
    paypal_disconnect_removes_payout_rail: false,
    paypal_disconnect_blocks_publishing: false,
    payout_setup_method: "bank_account",
  },
  connect_account_fee_info_text: "",
});

describe("FormPage gifting preview", () => {
  afterEach(cleanup);

  it("shows the gift section in the preview when gifting is enabled", () => {
    render(<FormPage {...props(false)} />);
    expect(screen.queryByText("Give as a gift?")).not.toBeNull();
  });

  it("hides the gift section in the preview when gifting is disabled", () => {
    render(<FormPage {...props(true)} />);
    expect(screen.queryByText("Give as a gift?")).toBeNull();
  });

  // The reported bug: the preview kept the gift section until the page was saved and reloaded.
  it("updates the preview as soon as the toggle changes, before any save", () => {
    render(<FormPage {...props(false)} />);
    expect(screen.queryByText("Give as a gift?")).not.toBeNull();

    fireEvent.click(screen.getByRole("switch", { name: /purchase your products as gifts/u }));

    expect(screen.queryByText("Give as a gift?")).toBeNull();
  });
});
