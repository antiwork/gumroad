// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Discount } from "$app/parsers/checkout";
import { assertDefined } from "$app/utils/assert";

import { Product, type Product as ProductData, type ProductDiscount } from "$app/components/Product";
import type { PriceSelection } from "$app/components/Product/ConfigurationSelector";

// The price the product page ends up showing. `discountedPriceCents < priceCents` is what
// says the seller's auto-applied code produced the displayed price.
const prices = vi.hoisted(() => ({ priceCents: 2_000, discountedPriceCents: 1_400, pppDiscounted: false }));

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", {
  checkout_url: () => "https://example.com/checkout",
  edit_link_url: () => "https://example.com/edit",
  license_key_lookup_url: () => "https://example.com/license-key-lookup",
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
vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => "https://example.com/l/sale" }));
vi.mock("$app/components/useRunOnce", () => ({ useRunOnce: vi.fn() }));
vi.mock("$app/components/DomainSettings", () => ({
  useAppDomain: () => "example.com",
  useDomains: () => ({ scheme: "https", rootDomain: "example.com" }),
}));
vi.mock("$app/components/Product/ConfigurationSelector", () => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return {
    ConfigurationSelector,
    applySelection: () => ({
      basePriceCents: prices.priceCents,
      priceCents: prices.priceCents,
      discountedPriceCents: prices.discountedPriceCents,
      pppDiscounted: prices.pppDiscounted,
      isPWYW: false,
      maxQuantity: null,
      selectedOption: null,
      hasRentOption: false,
      hasMultipleRecurrences: false,
      hasConfigurableQuantity: false,
    }),
    buyerLocalPriceCentsForSelection: (priceCents?: number) => priceCents,
    hasMetDiscountConditions: () => true,
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
  vi.clearAllMocks();
  prices.priceCents = 2_000;
  prices.discountedPriceCents = 1_400;
  prices.pppDiscounted = false;
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

const product = (overrides: Partial<ProductData> = {}): ProductData => ({
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
  ...overrides,
});

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

const renderProduct = (productOverrides: Partial<ProductData> = {}, saleLabel: string | null = "Black Friday") =>
  render(
    <Product
      product={product(productOverrides)}
      purchase={null}
      discountCode={autoAppliedCode}
      saleLabel={saleLabel}
      selection={selection}
      disableAnalytics
    />,
  );

describe("product page sale label", () => {
  it("shows the seller's label beside the price their code produced", () => {
    renderProduct();

    expect(screen.getByTestId("sale-label").textContent).toBe("Black Friday");
  });

  it("hides the label when a purchasing-power discount produced the price", () => {
    prices.pppDiscounted = true;

    renderProduct();

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });

  it("hides the label when the selection does not meet the code's minimum quantity", () => {
    prices.discountedPriceCents = prices.priceCents;

    renderProduct();

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });

  it("hides the label when the page sends none", () => {
    renderProduct({}, null);

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });

  it("shows the label for a product whose price lives in the configuration selector", () => {
    renderProduct({
      options: [
        {
          id: "option",
          name: "Option",
          quantity_left: null,
          description: "",
          price_difference_cents: 0,
          recurrence_price_values: null,
          is_pwyw: false,
          duration_in_minutes: null,
        },
      ],
    });

    expect(screen.getByTestId("sale-label").textContent).toBe("Black Friday");
  });

  it("shows the label in a banner with the code's amount", () => {
    renderProduct();

    const banner = screen.getByTestId("sale-banner");
    expect(banner.textContent).toContain("Black Friday");
    expect(banner.textContent).toContain("30% off");
    expect(screen.queryByText(/off will be applied at checkout/u)).toBeNull();
  });

  it("keeps the minimum spend and expiry when the sale banner replaces the code message", () => {
    render(
      <Product
        product={product()}
        purchase={null}
        discountCode={{
          ...autoAppliedCode,
          discount: {
            ...sellerDiscount,
            minimum_amount_cents: 1_000,
            expires_at: new Date(Date.now() + 60_000).toISOString(),
          },
        }}
        saleLabel="Black Friday"
        selection={selection}
        disableAnalytics
      />,
    );

    expect(screen.getByText(/This discount will apply when you spend/u).textContent).toContain("$10");
    expect(screen.getByText(/This discount expires in/u)).toBeTruthy();
    expect(screen.queryByText(/off will be applied at checkout/u)).toBeNull();
  });

  it("shows the end date when a distant expiry is the automatic sale's only term", () => {
    render(
      <Product
        product={product()}
        purchase={null}
        discountCode={{
          ...autoAppliedCode,
          discount: { ...sellerDiscount, expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString() },
        }}
        saleLabel="Black Friday"
        selection={selection}
        disableAnalytics
      />,
    );

    expect(screen.getByText(/This sale ends on/u)).toBeTruthy();
    expect(screen.queryByText(/off will be applied at checkout/u)).toBeNull();
  });
});

describe("product page price and sale banner placement", () => {
  it("renders one banner and price before the description", () => {
    const { container } = renderProduct({ description_html: "<p>About this product</p>" });
    const banner = screen.getByTestId("sale-banner");
    const price = assertDefined(container.querySelector("[itemprop=price]"));
    expect(container.querySelectorAll("[itemprop=price]")).toHaveLength(1);

    const elements = Array.from(container.querySelectorAll("*"));
    const titleIndex = elements.indexOf(screen.getByRole("heading", { level: 1 }));
    const descriptionIndex = elements.indexOf(screen.getByText("About this product"));
    expect(elements.indexOf(banner)).toBeGreaterThan(titleIndex);
    expect(elements.indexOf(price)).toBeGreaterThan(elements.indexOf(banner));
    expect(elements.indexOf(price)).toBeLessThan(descriptionIndex);
    expect(descriptionIndex).toBeLessThan(elements.indexOf(screen.getByRole("link", { name: "I want this!" })));
  });
});
