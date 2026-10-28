// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Product, type Product as ProductData } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { WaitlistForm } from "$app/components/Product/WaitlistForm";

const mocks = vi.hoisted(() => ({ followSeller: vi.fn() }));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
});

vi.mock("$app/data/follow_seller", () => ({ followSeller: mocks.followSeller }));
vi.mock("$app/data/user_action_event", () => ({ trackUserProductAction: vi.fn().mockResolvedValue(undefined) }));
vi.mock("$app/data/view_event", () => ({ incrementProductViews: vi.fn() }));
vi.mock("$app/utils/user_analytics", () => ({
  startTrackingForSeller: vi.fn(),
  trackBuyerCurrencyDisplayView: vi.fn(),
  trackProductEvent: vi.fn(),
}));
vi.mock("$app/components/LoggedInUser", () => ({ useLoggedInUser: () => null }));
vi.mock("$app/components/RichTextEditor", () => ({ useRichTextEditor: () => null }));
vi.mock("$app/components/useAddThirdPartyAnalytics", () => ({ useAddThirdPartyAnalytics: () => vi.fn() }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://example.com/l/membership",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
vi.mock("$app/components/Product/ConfigurationSelector", async (importOriginal) => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return { ...(await importOriginal<object>()), ConfigurationSelector };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
// Stubbed so the page test does not need the share popover's portal; ShareSection.test.tsx covers
// the real section.
vi.mock("$app/components/Product/ShareSection", () => ({
  ShareSection: () => <div data-testid="share-section" />,
}));

afterEach(cleanup);
beforeEach(() => mocks.followSeller.mockReset());

const selection: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: "monthly",
  callStartTime: null,
  payInInstallments: false,
};

const unpublishedProduct = (overrides: Partial<ProductData> = {}): ProductData => ({
  id: "membership",
  name: "Membership",
  seller: {
    id: "seller-1",
    name: "Testy",
    avatar_url: "",
    profile_url: "https://example.com/testy",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/membership",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 0,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: true,
  is_recurring_billing: true,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "membership",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: false,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "membership",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
  options: [],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  waitlist_enabled: false,
  waitlist_count: null,
  follow_recaptcha_site_key: null,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
  ...overrides,
});

const renderProduct = (overrides: Partial<ProductData> = {}) =>
  render(<Product product={unpublishedProduct(overrides)} purchase={null} selection={selection} disableAnalytics />);

const renderForm = (overrides: Partial<ProductData> = {}) =>
  render(<WaitlistForm product={unpublishedProduct({ waitlist_enabled: true, ...overrides })} />);

const submit = (email: string) => {
  fireEvent.change(screen.getByLabelText("Your email address"), { target: { value: email } });
  fireEvent.click(screen.getByRole("button", { name: "Notify me" }));
};

describe("product page waitlist", () => {
  it("offers the waitlist in place of the not-for-sale warning", () => {
    renderProduct({ waitlist_enabled: true });

    expect(screen.getByRole("status").textContent).toBe("Coming soon");
    expect(screen.getByRole("button", { name: "Notify me" })).toBeTruthy();
    expect(screen.queryByText("This product is not currently for sale.")).toBeNull();
  });

  it("keeps the summary card and the share links", () => {
    renderProduct({ waitlist_enabled: true, summary: "A membership for makers." });

    expect(screen.getByText("A membership for makers.")).toBeTruthy();
    expect(screen.getByTestId("share-section")).toBeTruthy();
  });

  it("leaves the unpublished page alone while the switch is off", () => {
    renderProduct({ waitlist_enabled: false });

    expect(screen.getByText("This product is not currently for sale.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Notify me" })).toBeNull();
    expect(screen.getByTestId("share-section")).toBeTruthy();
  });
});

describe("waitlist form", () => {
  it("follows the seller for the product the visitor asked about", async () => {
    mocks.followSeller.mockResolvedValue({
      success: true,
      message: "Check your inbox to confirm your follow request.",
      confirmed: false,
    });
    renderForm();

    submit("buyer@example.com");

    expect(await screen.findByRole("status")).toHaveProperty(
      "textContent",
      "You're on the list. Check your inbox to confirm.",
    );
    expect(mocks.followSeller).toHaveBeenCalledWith("buyer@example.com", "seller-1", null, "membership");
  });

  it("tells an already-confirmed subscriber that the launch email is coming", async () => {
    mocks.followSeller.mockResolvedValue({
      success: true,
      message: "You are now following Testy!",
      confirmed: true,
    });
    renderForm();

    submit("buyer@example.com");

    expect(await screen.findByRole("status")).toHaveProperty(
      "textContent",
      "You're on the list. We'll email you when it launches.",
    );
  });

  it("refuses an address the follow form would refuse, without calling the endpoint", () => {
    renderForm();

    submit("not-an-email");

    expect(screen.getByRole("alert").textContent).toBe("Please enter a valid email address.");
    expect(mocks.followSeller).not.toHaveBeenCalled();
  });

  it("keeps the button inactive on the seller's own page", () => {
    renderForm({ can_edit: true });

    expect(screen.getByRole("button", { name: "Notify me" })).toHaveProperty("disabled", true);

    fireEvent.click(screen.getByRole("button", { name: "Notify me" }));
    expect(mocks.followSeller).not.toHaveBeenCalled();
  });

  it("shows the count only to the page that sends one", () => {
    renderForm({ waitlist_count: 1 });
    expect(screen.getByText("1 person is on the waitlist.")).toBeTruthy();

    cleanup();
    renderForm({ waitlist_count: 4 });
    expect(screen.getByText("4 people are on the waitlist.")).toBeTruthy();

    cleanup();
    renderForm();
    expect(screen.queryByText(/on the waitlist\.$/u)).toBeNull();
  });
});
