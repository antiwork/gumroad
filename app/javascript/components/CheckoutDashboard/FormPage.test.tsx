// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
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

const props = (giftingDisabled: boolean, user: Partial<FormPageProps["user"]> = {}): FormPageProps => ({
  pages: [],
  user: {
    display_offer_code_field: false,
    recommendation_type: "no_recommendations",
    tipping_enabled: false,
    ach_payments_enabled: false,
    gifting_disabled: giftingDisabled,
    link_disabled: false,
    paypal_card_funding_disabled: false,
    ...user,
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
  connect_account_fee_info: { summary: "", items: [] },
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

describe("FormPage payment method switches", () => {
  afterEach(cleanup);

  const switchFor = (name: RegExp) => screen.getByRole("switch", { name });

  it("offers Link and PayPal's card funding button by default", () => {
    render(<FormPage {...props(false)} />);

    expect(switchFor(/offer stripe link at checkout/iu)).toHaveProperty("checked", true);
    expect(switchFor(/show paypal's debit or credit card button/iu)).toHaveProperty("checked", true);
  });

  it("shows a seller who has switched both off as unchecked", () => {
    render(<FormPage {...props(false, { link_disabled: true, paypal_card_funding_disabled: true })} />);

    expect(switchFor(/offer stripe link at checkout/iu)).toHaveProperty("checked", false);
    expect(switchFor(/show paypal's debit or credit card button/iu)).toHaveProperty("checked", false);
  });
});

describe("FormPage radio groups", () => {
  afterEach(cleanup);

  // Each option used to carry no `name`, so every option was its own native group: Tab stopped
  // on each of them and the fieldset's options were not announced as one choice set.
  it("gives each radio set one shared name, and keeps the two sets separate", () => {
    render(<FormPage {...props(false)} />);

    const groupNamed = (name: string) => screen.getByRole("group", { name });
    const radiosIn = (name: string) => within(groupNamed(name)).getAllByRole<HTMLInputElement>("radio");
    // The shared name of a set, failing the test if the options do not all agree on one.
    const sharedName = (radios: HTMLInputElement[]) => {
      const names = new Set(radios.map((radio) => radio.name));
      expect([...names]).toHaveLength(1);
      return radios[0]?.name ?? "";
    };

    const discountField = radiosIn("Add discount code field to purchase form");
    expect(discountField).toHaveLength(2);
    expect(sharedName(discountField)).not.toBe("");

    const recommendations = radiosIn("Product recommendations during checkout");
    expect(recommendations).toHaveLength(4);

    // Two sets, two names — a shared name across both would make them one group.
    expect(sharedName(recommendations)).not.toBe(sharedName(discountField));

    // One choice set still behaves as one: picking an option clears the other.
    const discountGroup = groupNamed("Add discount code field to purchase form");
    const never = within(discountGroup).getByLabelText<HTMLInputElement>("Never");
    const onlyIfAvailable = within(discountGroup).getByLabelText<HTMLInputElement>("Only if a discount is available");
    expect(never.checked).toBe(true);

    fireEvent.click(onlyIfAvailable);

    expect(onlyIfAvailable.checked).toBe(true);
    expect(never.checked).toBe(false);
  });
});
