// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Product, type Product as ProductData } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
});

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
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

afterEach(cleanup);

const recurrences = (overrides: Partial<NonNullable<ProductData["recurrences"]>> = {}) => ({
  default: "yearly" as const,
  enabled: [
    { recurrence: "monthly" as const, price_cents: 1_000, id: "monthly", renewal_reminder_days: [1] },
    { recurrence: "yearly" as const, price_cents: 10_000, id: "yearly", renewal_reminder_days: [30, 7] },
  ],
  free_trial_reminder_days: null,
  ...overrides,
});

const membership = (overrides: Partial<ProductData> = {}): ProductData => ({
  id: "membership",
  name: "Membership",
  seller: null,
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/membership",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 1_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: true,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "membership",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: true,
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
  recurrences: recurrences(),
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

const yearly: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: "yearly",
  callStartTime: null,
  payInInstallments: false,
};

// Owns the selection like the real page does, so the actual recurrence select drives the notice.
const ProductPage = ({ product }: { product: ProductData }) => {
  const [selection, setSelection] = React.useState(yearly);
  return (
    <Product product={product} purchase={null} selection={selection} setSelection={setSelection} disableAnalytics />
  );
};

const notice = () => screen.queryByRole("note")?.textContent ?? null;

describe("product page renewal reminder notice", () => {
  it("states the lead times of the selected recurrence and follows a recurrence change", () => {
    render(<ProductPage product={membership()} />);

    expect(notice()).toBe("We'll email you a reminder 30 days and 7 days before each renewal.");

    fireEvent.change(screen.getByLabelText("Recurrence"), { target: { value: "monthly" } });

    expect(notice()).toBe("We'll email you a reminder 1 day before each renewal.");
  });

  it("names the trial-ending email instead of promising the renewal reminders before the first charge", () => {
    render(
      <ProductPage
        product={membership({
          free_trial: { duration: { amount: 1, unit: "week" } },
          recurrences: recurrences({ free_trial_reminder_days: 2 }),
        })}
      />,
    );

    expect(notice()).toBe(
      "If this purchase starts your free trial, we'll email you a reminder 2 days before it ends. We'll also email you 30 days and 7 days before each renewal after your first payment.",
    );
  });

  it("shows nothing when renewal reminders are off for the seller", () => {
    render(
      <ProductPage
        product={membership({
          recurrences: recurrences({
            enabled: [
              { recurrence: "monthly", price_cents: 1_000, id: "monthly", renewal_reminder_days: [] },
              { recurrence: "yearly", price_cents: 10_000, id: "yearly", renewal_reminder_days: [] },
            ],
          }),
        })}
      />,
    );

    expect(screen.queryByRole("note")).toBeNull();
  });

  it("shows nothing for a fixed-length membership that charges only once", () => {
    render(<ProductPage product={membership({ duration_in_months: 12 })} />);

    expect(screen.queryByRole("note")).toBeNull();
  });
});
