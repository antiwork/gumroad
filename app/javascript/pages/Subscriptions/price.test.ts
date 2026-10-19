import { describe, expect, it } from "vitest";

import {
  applyPlanChangeSelection,
  initialSubscriptionUnitPrice,
  selectedSubscriptionTotal,
  subscriptionPWYWMinimumUnitPrice,
  withOncePerCartMinimum,
} from "$app/pages/Subscriptions/price";
import type { Discount } from "$app/parsers/checkout";

import type { PriceSelection, Product } from "$app/components/Product/ConfigurationSelector";

const oncePerCartDiscount: Discount = {
  type: "fixed",
  cents: 100,
  once_per_cart: true,
  product_ids: null,
  expires_at: null,
  minimum_quantity: null,
  duration_in_billing_cycles: null,
  minimum_amount_cents: null,
};

describe("subscription pricing", () => {
  it("uses the pre-discount unit price for a cart-level discount", () => {
    const unitPrice = initialSubscriptionUnitPrice({
      price: 1_900,
      pre_discount_price: 2_000,
      quantity: 2,
      discount: oncePerCartDiscount,
      is_installment_plan: false,
    });

    expect(unitPrice).toBe(1_000);
    expect(selectedSubscriptionTotal({ unitPrice, quantity: 3, discount: oncePerCartDiscount, minimumPrice: 99 })).toBe(
      2_900,
    );
    expect(subscriptionPWYWMinimumUnitPrice(1_000, 900, oncePerCartDiscount)).toBe(1_000);
  });

  it("keeps legacy per-item pricing unchanged", () => {
    const discount = { ...oncePerCartDiscount, once_per_cart: false };
    const unitPrice = initialSubscriptionUnitPrice({
      price: 1_800,
      pre_discount_price: 2_000,
      quantity: 2,
      discount,
      is_installment_plan: false,
    });

    expect(unitPrice).toBe(900);
    expect(selectedSubscriptionTotal({ unitPrice, quantity: 3, discount, minimumPrice: 99 })).toBe(2_700);
    expect(subscriptionPWYWMinimumUnitPrice(1_000, 900, discount)).toBe(900);
    expect(withOncePerCartMinimum(50, discount, 99)).toBe(50);
  });

  it("keeps a positive cart-discount total at the currency minimum", () => {
    expect(
      selectedSubscriptionTotal({ unitPrice: 75, quantity: 2, discount: oncePerCartDiscount, minimumPrice: 99 }),
    ).toBe(99);
    expect(withOncePerCartMinimum(50, oncePerCartDiscount, 99)).toBe(99);
  });

  it("keeps installment plans at the next installment price", () => {
    const unitPrice = initialSubscriptionUnitPrice({
      price: 900,
      pre_discount_price: 3_000,
      quantity: 1,
      discount: oncePerCartDiscount,
      is_installment_plan: true,
    });

    expect(unitPrice).toBe(900);
    expect(selectedSubscriptionTotal({ unitPrice, quantity: 1, discount: null, minimumPrice: 99 })).toBe(900);
  });
});

describe("subscription discount eligibility on plan changes", () => {
  const tier = (quantityLeft: number | null): Product["options"][number] => ({
    id: "basic",
    name: "Basic",
    quantity_left: quantityLeft,
    description: "",
    price_difference_cents: 0,
    recurrence_price_values: { monthly: { price_cents: 1_000, suggested_price_cents: null } },
    is_pwyw: false,
    duration_in_minutes: null,
  });
  const product = (quantityLeft: number | null): Product => ({
    id: "membership",
    permalink: "membership",
    rental: null,
    options: [tier(quantityLeft)],
    currency_code: "usd",
    price_cents: 0,
    installment_plan: null,
    is_tiered_membership: true,
    is_legacy_subscription: false,
    is_quantity_enabled: false,
    is_multiseat_license: true,
    quantity_remaining: null,
    recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 0, id: "monthly" }] },
    pwyw: null,
    ppp_details: null,
    native_type: "membership",
  });
  const discount: Discount = {
    type: "percent",
    percents: 30,
    product_ids: null,
    expires_at: null,
    minimum_quantity: null,
    duration_in_billing_cycles: null,
    minimum_amount_cents: null,
  };
  const selection = (quantity: number): PriceSelection => ({
    rent: false,
    optionId: "basic",
    price: { value: null, error: false },
    quantity,
    recurrence: "monthly",
    callStartTime: null,
    payInInstallments: false,
  });

  it("drops the code on an option the server left out of its scope", () => {
    const { discountedPriceCents } = applyPlanChangeSelection(product(null), { basic: null }, discount, selection(1));

    expect(discountedPriceCents).toBe(1_000);
  });

  it("keeps a seat-minimum code on the subscriber's sold-out tier", () => {
    const seatMinimum = { ...discount, minimum_quantity: 2 };
    const { discountedTotalCents } = applyPlanChangeSelection(
      product(0),
      { basic: seatMinimum },
      seatMinimum,
      selection(2),
    );

    expect(discountedTotalCents).toBe(1_400);
  });

  it("drops a seat-minimum code when the plan has too few seats", () => {
    const seatMinimum = { ...discount, minimum_quantity: 2 };
    const { discountedTotalCents } = applyPlanChangeSelection(
      product(null),
      { basic: seatMinimum },
      seatMinimum,
      selection(1),
    );

    expect(discountedTotalCents).toBe(1_000);
  });
});
