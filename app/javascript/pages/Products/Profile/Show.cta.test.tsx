// @vitest-environment happy-dom
import { cleanup, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import ProfileProductShowPage from "$app/pages/Products/Profile/Show";

import type { Product as ProductData } from "$app/components/Product";

const pageProps = vi.hoisted((): { props: Record<string, unknown> } => ({ props: {} }));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
  edit_link_url: () => "https://example.com/products/edit",
});
vi.mock("@inertiajs/react", () => ({ usePage: () => ({ props: pageProps.props }) }));
// The wordmark/header around the product is not what this test is about.
vi.mock("$app/components/Profile/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
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
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "https://example.com/products/permalink",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const product: ProductData = {
  id: "permalink",
  name: "Harbor Lantern",
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
  long_url: "https://example.com/l/permalink",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 4_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: "pay_prompt",
  permalink: "permalink",
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

beforeEach(() => {
  pageProps.props = {
    product,
    purchase: null,
    discount_code: null,
    sale_label: null,
    wishlists: [],
    main_section_index: 0,
    sections: [],
    currency_code: "usd",
    creator_profile: { external_id: "seller", name: "Seller" },
  };
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
  vi.stubGlobal(
    "ResizeObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("storefront product page", () => {
  it("uses the seller's call to action instead of forcing Add to cart", () => {
    render(<ProfileProductShowPage />);

    expect(within(screen.getByRole("article")).getByRole("link", { name: "Pay" })).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Add to cart" })).toBeNull();
  });
});
