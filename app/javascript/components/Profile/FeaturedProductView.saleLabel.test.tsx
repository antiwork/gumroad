// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { type Product as ProductData, type ProductDiscount } from "$app/components/Product";
import { FeaturedProductView } from "$app/components/Profile/Sections";

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
vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => "https://example.com/l/sale" }));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
// Only the selector UI is stubbed: the page prices the product with the real applySelection.
vi.mock("$app/components/Product/ConfigurationSelector", async (importOriginal) => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return { ...(await importOriginal<object>()), ConfigurationSelector };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

afterEach(cleanup);

const product: ProductData = {
  id: "sale",
  name: "Sale",
  seller: null,
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/sale",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 2_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "sale",
  preorder: null,
  description_html: "",
  is_compliance_blocked: false,
  is_published: true,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "digital",
  sales_count: null,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: null,
  options: [],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
};

const sellerDiscount: Discount = {
  type: "percent",
  percents: 30,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

const autoAppliedCode: ProductDiscount = { valid: true, code: "blackfriday", discount: sellerDiscount };

describe("featured profile product sale", () => {
  it("shows the seller's sale banner and the discounted price", () => {
    const { container } = render(
      <FeaturedProductView
        props={{
          product,
          purchase: null,
          discount_code: autoAppliedCode,
          sale_label: "Black Friday",
          wishlists: [],
        }}
      />,
    );

    const banner = screen.getByTestId("sale-banner");
    expect(banner.textContent).toContain("Black Friday");
    expect(banner.textContent).toContain("30% off");
    expect(container.querySelector("[itemprop=price]")?.textContent).toContain("$14");
  });
});
