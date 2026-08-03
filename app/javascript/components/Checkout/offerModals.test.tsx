// @vitest-environment happy-dom
import { render } from "@testing-library/react";
import * as React from "react";
import { describe, expect, it, vi } from "vitest";

import {
  getDiscountedPrice,
  type CartItem,
  type CartState,
  type CrossSell,
  type Product,
} from "$app/components/Checkout/cartState";
import { CrossSellModal } from "$app/components/Checkout/CrossSellModal";
import { UpsellModal, type OfferedUpsell } from "$app/components/Checkout/UpsellModal";
import {
  applySelection,
  computeSelectionDiscountedPrice,
  type Option,
  withConfiguredOncePerCartAmount,
} from "$app/components/Product/ConfigurationSelector";

const product = (overrides: Partial<Product> = {}): Product => ({
  id: "product-id",
  permalink: "product",
  name: "Product",
  creator: { id: "seller-id", name: "Seller", profile_url: "#", avatar_url: "" },
  url: "#",
  thumbnail_url: null,
  currency_code: "usd",
  price_cents: 1_000,
  quantity_remaining: null,
  pwyw: null,
  installment_plan: null,
  is_preorder: false,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_multiseat_license: false,
  is_quantity_enabled: false,
  free_trial: null,
  options: [],
  recurrences: null,
  duration_in_months: null,
  native_type: "digital",
  custom_fields: [],
  require_shipping: false,
  supports_paypal: null,
  has_offer_codes: true,
  has_tipping_enabled: false,
  analytics: { google_analytics_id: null, facebook_pixel_id: null, tiktok_pixel_id: null, free_sales: false },
  exchange_rate: 1,
  rental: null,
  shippable_country_codes: [],
  ppp_details: null,
  upsell: null,
  cross_sells: [],
  archived: false,
  can_gift: false,
  bundle_products: [],
  ...overrides,
});

const cartItem = (itemProduct: Product, overrides: Partial<CartItem> = {}): CartItem => ({
  product: itemProduct,
  price: itemProduct.price_cents,
  quantity: 1,
  recurrence: null,
  option_id: null,
  recommended_by: null,
  affiliate_id: null,
  rent: false,
  url_parameters: {},
  referrer: "",
  recommender_model_name: null,
  call_start_time: null,
  pay_in_installments: false,
  force_new_subscription: false,
  ...overrides,
});

const discount = {
  type: "fixed" as const,
  cents: 100,
  once_per_cart: true,
  once_per_cart_id: "discount-id",
  once_per_cart_amount_cents: 100,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

describe("checkout offer modals", () => {
  it("does not present a cart-level fixed discount as a per-unit price", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 2,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };

    expect(applySelection(product(), discount, selection)).toMatchObject({
      priceCents: 1_000,
      discountedPriceCents: 1_000,
      discountedTotalCents: 1_900,
      pppDiscounted: false,
    });
  });

  it("keeps a positive cart-level discounted total at the currency minimum", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 1,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };
    const nearFreeDiscount = { ...discount, cents: 950, once_per_cart_amount_cents: 950 };

    expect(applySelection(product(), nearFreeDiscount, selection)).toMatchObject({
      discountedPriceCents: 99,
      discountedTotalCents: 99,
      pppDiscounted: false,
    });
  });

  it("keeps a fully discounted cart-level total free", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 1,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };
    const freeDiscount = { ...discount, cents: 1_000, once_per_cart_amount_cents: 1_000 };

    expect(applySelection(product(), freeDiscount, selection)).toMatchObject({
      discountedPriceCents: 0,
      discountedTotalCents: 0,
      pppDiscounted: false,
    });
  });

  it("still chooses PPP when it beats the cart-level fixed discount", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 2,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };

    expect(
      applySelection(product({ ppp_details: { country: "US", factor: 0.8, minimum_price: 0 } }), discount, selection),
    ).toMatchObject({ discountedPriceCents: 800, discountedTotalCents: 1_600, pppDiscounted: true });
  });

  it("compares PPP with the full quantity-wide cart discount", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 10,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };
    const cartDiscount = { ...discount, cents: 500, once_per_cart_amount_cents: 500 };

    expect(
      applySelection(
        product({ ppp_details: { country: "US", factor: 0.8, minimum_price: 0 } }),
        cartDiscount,
        selection,
      ),
    ).toMatchObject({ discountedPriceCents: 800, pppDiscounted: true });
  });

  it("compares PPP with the configured amount on a covered zero-allocation line", () => {
    const zeroAllocation = { ...discount, cents: 0 };
    const comparison = computeSelectionDiscountedPrice(
      1_000,
      withConfiguredOncePerCartAmount(zeroAllocation),
      product({ ppp_details: { country: "US", factor: 0.95, minimum_price: 0 } }),
      1,
    );

    expect(comparison.ppp).toBe(false);
    expect(comparison.value).toBe(900);
  });

  it("reprices a selected option with the configured cart discount", () => {
    const option: Product["options"][number] = {
      id: "option-id",
      name: "Upgrade",
      quantity_left: null,
      description: "",
      price_difference_cents: 1_000,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
      upsell_offered_variant_id: null,
    };
    const selection = {
      rent: false,
      optionId: option.id,
      price: { error: false, value: null },
      quantity: 1,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };
    const partiallyAllocatedDiscount = { ...discount, cents: 1_000, once_per_cart_amount_cents: 1_500 };

    expect(applySelection(product({ options: [option] }), partiallyAllocatedDiscount, selection)).toMatchObject({
      priceCents: 2_000,
      discountedPriceCents: 500,
      discountedTotalCents: 500,
    });
  });

  it("preserves an already allocated cart discount fragment", () => {
    const selection = {
      rent: false,
      optionId: null,
      price: { error: false, value: null },
      quantity: 1,
      recurrence: null,
      callStartTime: null,
      payInInstallments: false,
    };
    const allocatedFragment = { ...discount, cents: 500, once_per_cart_amount_cents: 1_500 };

    expect(
      applySelection(product({ price_cents: 2_000 }), allocatedFragment, selection, {
        preserveOncePerCartAllocation: true,
      }),
    ).toMatchObject({ discountedPriceCents: 1_500, discountedTotalCents: 1_500 });
  });

  it("shows the line total for a multi-quantity once-per-cart upsell", () => {
    const itemProduct = product();
    const item = cartItem(itemProduct, { quantity: 2 });
    const offeredOption: Option = {
      id: "option-id",
      name: "Upgrade",
      quantity_left: null,
      description: "",
      price_difference_cents: 0,
      recurrence_price_values: null,
      is_pwyw: false,
      duration_in_minutes: null,
    };
    const upsell: OfferedUpsell = { id: "upsell-id", text: "Upgrade", description: "Upgrade", item, offeredOption };
    const cart: CartState = {
      items: [item],
      discountCodes: [{ code: "SAVE", products: { [itemProduct.permalink]: discount }, fromUrl: false }],
    };

    const view = render(<UpsellModal upsell={upsell} accept={vi.fn()} decline={vi.fn()} cart={cart} />);

    expect(view.getByText("$20")).toBeTruthy();
    expect(view.getByText("$19")).toBeTruthy();
  });

  it("prices a replacement cross-sell against the accepted cart", () => {
    const offeredProduct = product({ id: "offered-id", permalink: "offered", price_cents: 2_000 });
    const acceptedItem = cartItem(offeredProduct, {
      accepted_offer: { id: "cross-sell-id", discount: null },
    });
    const crossSell: CrossSell = {
      id: "cross-sell-id",
      replace_selected_products: true,
      text: "Upgrade",
      description: "Upgrade",
      offered_product: {
        product: offeredProduct,
        recurrence: null,
        price: 2_000,
        option_id: null,
        rent: false,
        quantity: 1,
        affiliate_id: null,
        recommended_by: null,
        call_start_time: null,
        accepted_offer: null,
        pay_in_installments: false,
        force_new_subscription: false,
      },
      discount: null,
      ratings: null,
    };
    const acceptedCart: CartState = {
      items: [acceptedItem],
      discountCodes: [{ code: "SAVE", products: { [offeredProduct.permalink]: discount }, fromUrl: false }],
    };

    const view = render(
      <CrossSellModal crossSell={crossSell} accept={vi.fn()} decline={vi.fn()} cart={acceptedCart} />,
    );

    expect(view.getAllByText("$19").length).toBeGreaterThan(0);
  });

  it("uses the accepted cross-sell discount instead of PPP", () => {
    const itemProduct = product({ ppp_details: { country: "LV", factor: 0.49, minimum_price: 0 } });
    const item = cartItem(itemProduct, { accepted_offer: { id: "cross-sell-id", discount } });

    expect(getDiscountedPrice({ items: [item], discountCodes: [] }, item)).toMatchObject({
      discount: { type: "cross-sell" },
      price: 900,
    });
  });
});
