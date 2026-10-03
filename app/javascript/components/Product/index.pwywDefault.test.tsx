// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { useSelectionFromUrl, type Product as ProductData } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";

const location = vi.hoisted(() => ({ url: "https://example.com/products/free" }));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
});

vi.mock("$app/utils/classNames", () => ({
  classNames: (...xs: unknown[]) => xs.filter((x): x is string => typeof x === "string" && x.length > 0).join(" "),
}));
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
vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => location.url }));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));

afterEach(cleanup);

const baseProduct: ProductData = {
  id: "free",
  name: "Free",
  seller: {
    id: "seller",
    name: "Seller",
    avatar_url: "https://example.com/avatar.png",
    profile_url: "https://example.com/seller",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/products/free",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 0,
  pwyw: { suggested_price_cents: null },
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "free",
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

const readSelection = (product: ProductData): PriceSelection => {
  const out: { selection: PriceSelection | null } = { selection: null };
  const Harness = () => {
    const [selection] = useSelectionFromUrl(product);
    out.selection = selection;
    return null;
  };
  render(<Harness />);
  if (!out.selection) throw new Error("selection was not captured");
  return out.selection;
};

describe("useSelectionFromUrl price default", () => {
  it("starts a free product's pay-what-you-want amount at 0 so the CTA is not blocked", () => {
    location.url = "https://example.com/products/free";

    expect(readSelection(baseProduct).price.value).toBe(0);
  });

  it("keeps a ?price= prefill ahead of the free-product default", () => {
    location.url = "https://example.com/products/free?price=250";

    expect(readSelection(baseProduct).price.value).toBe(25_000);
  });

  it("leaves a paid pay-what-you-want amount empty for the buyer to name", () => {
    location.url = "https://example.com/products/free";

    expect(readSelection({ ...baseProduct, price_cents: 500 }).price.value).toBeNull();
  });

  it("leaves the amount empty when the selected option is itself priced", () => {
    location.url = "https://example.com/products/free";

    const product: ProductData = {
      ...baseProduct,
      options: [
        {
          id: "preset",
          name: "Preset",
          quantity_left: null,
          description: "",
          price_difference_cents: 300,
          recurrence_price_values: null,
          is_pwyw: true,
          duration_in_minutes: null,
        },
      ],
    };

    expect(readSelection(product).price.value).toBeNull();
  });
});
