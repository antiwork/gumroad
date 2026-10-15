// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { Discount } from "$app/parsers/checkout";

import { Product, type Product as ProductData, type ProductDiscount } from "$app/components/Product";
import type { Option, PriceSelection } from "$app/components/Product/ConfigurationSelector";

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
// Only the selector UI is stubbed: the page prices each tier with the real applySelection.
vi.mock("$app/components/Product/ConfigurationSelector", async (importOriginal) => {
  const ConfigurationSelector = React.forwardRef(() => null);
  ConfigurationSelector.displayName = "ConfigurationSelector";
  return { ...(await importOriginal<object>()), ConfigurationSelector };
});
vi.mock("$app/components/Product/Thumbnail", () => ({ Thumbnail: () => <div data-testid="thumbnail" /> }));
vi.mock("$app/components/Product/ShareSection", () => ({ ShareSection: () => null }));

afterEach(() => {
  cleanup();
});

const noTierSelected: PriceSelection = {
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: "monthly",
  callStartTime: null,
  payInInstallments: false,
};

const tier = (id: string, monthlyPriceCents: number): Option => ({
  id,
  name: id,
  quantity_left: null,
  description: "",
  price_difference_cents: 0,
  recurrence_price_values: { monthly: { price_cents: monthlyPriceCents, suggested_price_cents: null } },
  is_pwyw: false,
  duration_in_minutes: null,
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
  recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
  options: [tier("basic", 1_000), tier("pro", 2_000)],
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: true },
  has_third_party_analytics: false,
  ppp_details: null,
  can_edit: false,
  refund_policy: null,
  bundle_products: [],
  public_files: [],
  ...overrides,
});

const sellerDiscount = (optionIdsByProduct?: Record<string, string[]>, minimumAmountCents?: number): Discount => ({
  type: "percent",
  percents: 30,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: minimumAmountCents ?? null,
  ...(optionIdsByProduct ? { option_ids_by_product: optionIdsByProduct } : {}),
});

const renderMembership = (
  discount: Discount,
  productOverrides: Partial<ProductData> = {},
  selection: PriceSelection = noTierSelected,
) => {
  const autoAppliedCode: ProductDiscount = { valid: true, code: "blackfriday", discount };
  return render(
    <Product
      product={membership(productOverrides)}
      purchase={null}
      discountCode={autoAppliedCode}
      saleLabel="Black Friday"
      selection={selection}
      disableAnalytics
    />,
  );
};

describe("product page sale label with no tier selected", () => {
  it("shows the label when the code discounts only one of the tiers", () => {
    renderMembership(sellerDiscount({ membership: ["pro"] }));

    expect(screen.getByTestId("sale-label").textContent).toBe("Black Friday");
  });

  it("hides the label when the code discounts none of the tiers", () => {
    renderMembership(sellerDiscount({ membership: ["retired"] }));

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });

  it("ignores a sold-out tier the page hides", () => {
    renderMembership(sellerDiscount({ membership: ["pro"] }), {
      hide_sold_out_variants: true,
      options: [tier("basic", 1_000), { ...tier("pro", 2_000), quantity_left: 0 }],
    });

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });

  it("hides the label when a purchasing-power discount beats the code on every tier", () => {
    renderMembership(sellerDiscount(), { ppp_details: { country: "India", factor: 0.4, minimum_price: 99 } });

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });
});

const minimumAmountCents = 1_500;
const noRecurrenceSelected: PriceSelection = { ...noTierSelected, recurrence: null };

const digitalProduct = (overrides: Partial<ProductData> = {}): Partial<ProductData> => ({
  is_tiered_membership: false,
  is_recurring_billing: false,
  recurrences: null,
  native_type: "digital",
  options: [],
  ...overrides,
});

describe("product page sale label on a product with a nearly sold-out variant", () => {
  // $10 with one left and $5 unlimited: at quantity 2 only the $10 variant would reach the $15
  // minimum, but it can't be bought twice.
  const product = digitalProduct({
    price_cents: 0,
    is_quantity_enabled: true,
    options: [
      { ...tier("last-one", 0), price_difference_cents: 1_000, recurrence_price_values: null, quantity_left: 1 },
      { ...tier("unlimited", 0), price_difference_cents: 500, recurrence_price_values: null },
    ],
  });

  it("hides the label when no variant reaches the code's minimum amount at a quantity it can be bought in", () => {
    renderMembership(sellerDiscount(undefined, minimumAmountCents), product, { ...noRecurrenceSelected, quantity: 2 });

    expect(screen.queryByTestId("sale-label")).toBeNull();
  });
});

describe("automatic sale prices with a minimum spend", () => {
  it.each([
    { quantity: 1, stock: null, expectedPrice: "10" },
    { quantity: 2, stock: null, expectedPrice: "7" },
    { quantity: 2, stock: 1, expectedPrice: "10" },
  ])("shows $expectedPrice with quantity $quantity and stock $stock", ({ quantity, stock, expectedPrice }) => {
    const { container } = renderMembership(
      sellerDiscount(undefined, 1_500),
      digitalProduct({ price_cents: 1_000, is_quantity_enabled: true, quantity_remaining: stock }),
      { ...noRecurrenceSelected, quantity },
    );

    expect(container.querySelector('[itemprop="price"]')?.getAttribute("content")).toBe(expectedPrice);
  });
});

describe("minimum spend on a price set by the buyer", () => {
  it.each([
    { enteredPrice: 1_000, checkoutPrice: 1_000 },
    { enteredPrice: 1_499, checkoutPrice: 1_499 },
    { enteredPrice: 1_500, checkoutPrice: 2_143 },
  ])("keeps the buyer's price of $enteredPrice consistent at checkout", ({ enteredPrice, checkoutPrice }) => {
    const { container } = renderMembership(
      sellerDiscount(undefined, 1_500),
      digitalProduct({ price_cents: 1_000, pwyw: { suggested_price_cents: 1_000 } }),
      { ...noRecurrenceSelected, price: { error: false, value: enteredPrice } },
    );
    const link = container.querySelector<HTMLAnchorElement>('a[href^="https://example.com/checkout"]');
    if (!link) throw new Error("Expected a checkout link");
    expect(new URL(link.href).searchParams.get("price")).toBe(checkoutPrice.toString());
  });
});
