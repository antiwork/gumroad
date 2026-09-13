// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Imported statically rather than inside a hook: the page pulls in typia and the Product tree, and
// transforming that graph inside a hook exceeds vitest's default hookTimeout.
import { incrementProductViews } from "$app/data/view_event";
import CoffeePage from "$app/pages/Users/Coffee";

import type { Product } from "$app/components/Product";

const mocks = vi.hoisted(() => ({ usePage: vi.fn() }));

vi.mock("@inertiajs/react", () => ({ usePage: mocks.usePage }));
vi.mock("$app/components/Profile/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("$app/components/Product/CoffeeProduct", () => ({ CoffeeProduct: () => <div /> }));
vi.mock("$app/data/view_event", () => ({ incrementProductViews: vi.fn() }));

// typia.assert runs for real against this fixture, so it doubles as a check that the props the
// coffee page claims to accept are the props it is handed.
const product = (overrides: Partial<Product> = {}): Product => ({
  id: "1",
  name: "Support me",
  seller: {
    id: "10",
    name: "Seller",
    avatar_url: "https://example.com/avatar.png",
    profile_url: "https://example.com",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/l/support-me",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 0,
  pwyw: { suggested_price_cents: 500 },
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "support-me",
  preorder: null,
  description_html: null,
  is_compliance_blocked: false,
  is_published: true,
  is_stream_only: false,
  streamable: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  is_licensed: false,
  native_type: "coffee",
  sales_count: 0,
  summary: null,
  attributes: [],
  free_trial: null,
  rental: null,
  recurrences: null,
  options: [
    {
      id: "option-1",
      name: "Tip",
      quantity_left: null,
      description: "",
      price_difference_cents: 500,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
    },
  ],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
  ...overrides,
});

const creatorProfile = {
  external_id: "10",
  avatar_url: "https://example.com/avatar.png",
  name: "Seller",
  twitter_handle: null,
  subdomain: "seller",
  is_verified: false,
  can_edit: false,
};

const renderPage = (overrides: Partial<Product> = {}) => {
  mocks.usePage.mockReturnValue({
    props: { product: product(overrides), purchase: null, creator_profile: creatorProfile },
  });
  return render(<CoffeePage />);
};

afterEach(cleanup);
beforeEach(() => {
  vi.mocked(incrementProductViews).mockClear();
  window.history.pushState({}, "", "/coffee");
});

describe("coffee page", () => {
  it("records a page view for the coffee product", () => {
    renderPage();

    expect(incrementProductViews).toHaveBeenCalledTimes(1);
    expect(incrementProductViews).toHaveBeenCalledWith({ permalink: "support-me", recommendedBy: null });
  });

  it("records the view once, not again on re-render", () => {
    const { rerender } = renderPage();
    rerender(<CoffeePage />);

    expect(incrementProductViews).toHaveBeenCalledTimes(1);
  });

  it("attributes the view to the product it was recommended by", () => {
    window.history.pushState({}, "", "/coffee?recommended_by=other-product");
    renderPage();

    expect(incrementProductViews).toHaveBeenCalledWith({
      permalink: "support-me",
      recommendedBy: "other-product",
    });
  });
});
