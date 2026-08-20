import { describe, expect, it } from "vitest";

import {
  initialSubscriptionUnitPrice,
  selectedSubscriptionTotal,
  subscriptionAmountDueToday,
  subscriptionPWYWMinimumUnitPrice,
  withOncePerCartMinimum,
} from "$app/pages/Subscriptions/price";
import type { Discount } from "$app/parsers/checkout";

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

  it("charges the new plan total when the membership is overdue", () => {
    expect(
      subscriptionAmountDueToday({
        newPriceCents: 179_400,
        currentPriceCents: 105_600,
        proratedDiscountCents: 26_400,
        minimumPriceCents: 99,
        isOverdueForCharge: true,
        isInFreeTrial: false,
        isAliveOrPendingCancellation: true,
        noChangesToCurrentPlan: false,
      }),
    ).toBe(179_400);
  });

  it("does not subtract proration from a same-plan overdue retry", () => {
    expect(
      subscriptionAmountDueToday({
        newPriceCents: 105_600,
        currentPriceCents: 105_600,
        proratedDiscountCents: 26_400,
        minimumPriceCents: 99,
        isOverdueForCharge: true,
        isInFreeTrial: false,
        isAliveOrPendingCancellation: true,
        noChangesToCurrentPlan: true,
      }),
    ).toBe(105_600);
  });

  it("still prorates an in-period upgrade", () => {
    expect(
      subscriptionAmountDueToday({
        newPriceCents: 1_794,
        currentPriceCents: 1_198,
        proratedDiscountCents: 1_000,
        minimumPriceCents: 99,
        isOverdueForCharge: false,
        isInFreeTrial: false,
        isAliveOrPendingCancellation: true,
        noChangesToCurrentPlan: false,
      }),
    ).toBe(794);
  });
});
