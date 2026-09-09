// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Product, type Product as ProductData } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { Layout } from "$app/components/Product/Layout";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
});

vi.mock("$app/utils/classNames", () => ({
  classNames: (...xs: unknown[]) => xs.filter((x): x is string => typeof x === "string" && x.length > 0).join(" "),
}));
vi.mock("$app/data/user_action_event", () => ({ trackUserProductAction: vi.fn() }));
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
  useOriginalLocation: () => "https://example.com/products/bundle",
}));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({ useAppDomain: () => "example.com" }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => false }));
vi.mock("$app/components/Product/ConfigurationSelector", () => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return {
    ConfigurationSelector,
    applySelection: (product: ProductData) => ({
      basePriceCents: product.price_cents,
      priceCents: product.price_cents,
      discountedPriceCents: product.price_cents,
      pppDiscounted: false,
      isPWYW: false,
      maxQuantity: null,
      selectedOption: null,
      hasRentOption: false,
      hasMultipleRecurrences: false,
      hasConfigurableQuantity: false,
    }),
    buyerLocalPriceCentsForSelection: (priceCents?: number) => priceCents,
    buyerLocalContextFor: (product: ProductData) => ({
      currencyCode: product.currency_code,
      buyerCurrency: product.buyer_currency,
      buyerLocalCurrencyRate: product.buyer_local_currency_rate,
      buyerLocalCurrencySubunitToUnit: product.buyer_local_currency_subunit_to_unit,
    }),
    withConfiguredOncePerCartAmount: (discount: unknown) => discount,
  };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

afterEach(() => {
  cleanup();
});

const selection: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
};

const product: ProductData = {
  id: "bundle",
  name: "Bundle",
  seller: {
    id: "seller",
    name: "Measure Twice Digital With A Very Long Creator Name",
    avatar_url: "https://example.com/avatar.png",
    profile_url: "https://example.com/measure-twice",
    is_verified: false,
  },
  collaborating_user: null,
  covers: [],
  main_cover_id: null,
  quantity_remaining: null,
  currency_code: "usd",
  long_url: "https://example.com/products/bundle",
  duration_in_months: null,
  is_sales_limited: false,
  price_cents: 1_000,
  pwyw: null,
  installment_plan: null,
  ratings: null,
  is_legacy_subscription: false,
  is_tiered_membership: false,
  is_recurring_billing: false,
  is_physical: false,
  custom_view_content_button_text: null,
  custom_button_text_option: null,
  permalink: "bundle",
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
  bundle_products: [
    {
      id: "bundle-product",
      name: "Long Bundle Item Name Without SpacesThatUsedToCollapse",
      ratings: { average: 4.8, count: 12 },
      price: 12_345,
      currency_code: "usd",
      thumbnail_url: null,
      native_type: "digital",
      url: "https://example.com/products/item",
      quantity: 1,
      variant: null,
    },
  ],
  public_files: [],
};

describe("product page bundle mobile layout", () => {
  it("renders mobile-safe price/seller and bundle item columns", () => {
    render(<Product product={product} purchase={null} selection={selection} disableAnalytics />);

    const seller = product.seller;
    if (!seller) throw new Error("expected a seller");
    const sellerLink = screen.getByRole("link", { name: seller.name });
    const summarySection = sellerLink.closest("section");
    expect(summarySection?.className.split(" ")).toEqual(expect.arrayContaining(["grid", "grid-cols-1"]));
    expect(summarySection?.className).not.toContain("grid-cols-[auto_1fr]");

    const bundleItem = screen.getByRole("listitem");
    expect(bundleItem.querySelector("figure")?.className.split(" ")).toEqual(
      expect.arrayContaining(["h-16", "w-16", "shrink-0", "sm:h-28", "sm:w-28"]),
    );

    const bundleProduct = product.bundle_products[0];
    if (!bundleProduct) throw new Error("expected a bundle product");
    const bundleLink = screen.getByRole("link", { name: bundleProduct.name });
    expect(bundleLink.closest("section")?.className.split(" ")).toEqual(expect.arrayContaining(["min-w-2/5"]));

    const bundlePrice = bundleItem.querySelector(".current-price");
    expect(bundlePrice?.className.split(" ")).toEqual(expect.arrayContaining(["current-price", "whitespace-nowrap"]));
    expect(bundlePrice?.closest("section")?.className.split(" ")).toEqual(
      expect.arrayContaining(["max-w-1/2", "shrink-0", "flex-row", "items-start"]),
    );

    expect(bundleLink.querySelector("h4")?.className.split(" ")).toEqual(expect.arrayContaining(["break-words"]));
    expect(screen.getByRole("heading", { name: product.name }).className.split(" ")).toEqual(
      expect.arrayContaining(["break-words"]),
    );

    const priceTag = document.querySelector("[itemprop='price']");
    expect(priceTag?.className.split(" ")).toEqual(expect.arrayContaining(["whitespace-nowrap"]));
    expect(priceTag?.closest("[itemprop='offers']")?.className.split(" ")).toEqual(
      expect.arrayContaining(["flex", "shrink-0"]),
    );

    const cta = screen.getByRole("link", { name: "I want this!" });
    expect(cta.className.split(" ")).toEqual(expect.arrayContaining(["whitespace-nowrap", "shrink-0"]));
  });

  it("lets the sticky CTA bar wrap instead of squeezing price and CTA", () => {
    class FakeIntersectionObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
    }
    vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);

    render(
      <Layout
        product={product}
        purchase={null}
        discount_code={null}
        wishlists={[]}
        main_section_index={0}
        sections={[]}
        creator_profile={{
          external_id: "seller",
          name: "Measure Twice Digital",
          avatar_url: "https://example.com/avatar.png",
          twitter_handle: null,
          subdomain: null,
          is_verified: false,
          can_edit: false,
        }}
        currency_code="usd"
      />,
    );

    const bar = screen.getByRole("region", { name: "Product information bar" });
    const inner = bar.querySelector(".max-w-product-page");
    expect(inner?.className.split(" ")).toEqual(expect.arrayContaining(["max-sm:flex-wrap"]));
    expect(bar.querySelector("[itemprop='price']")?.className.split(" ")).toEqual(
      expect.arrayContaining(["whitespace-nowrap"]),
    );
    const ctaWrap = bar.querySelector(".shrink-0.items-center");
    expect(ctaWrap?.className.split(" ")).toEqual(expect.arrayContaining(["shrink-0"]));
    expect(screen.getAllByRole("link", { name: "I want this!" })[0]?.className.split(" ")).toEqual(
      expect.arrayContaining(["whitespace-nowrap", "shrink-0"]),
    );
  });
});
