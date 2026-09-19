import { describe, expect, it } from "vitest";

import type { Option, PriceSelection, Product } from "$app/components/Product/ConfigurationSelector";
import { initialOptionId, isSelectionComplete, needsOptionChoice } from "$app/components/Product/purchaseReadiness";

const option = (id: string, extra: Partial<Option> = {}): Option => ({
  id,
  name: extra.name ?? id,
  quantity_left: extra.quantity_left ?? null,
  description: "",
  price_difference_cents: extra.price_difference_cents ?? 0,
  recurrence_price_values: null,
  is_pwyw: extra.is_pwyw ?? false,
  duration_in_minutes: null,
});

const product = (extra: Partial<Product> = {}): Product => ({
  permalink: "hxjlir",
  rental: null,
  options: [],
  currency_code: "usd",
  price_cents: 3999,
  installment_plan: null,
  is_tiered_membership: false,
  is_legacy_subscription: false,
  is_quantity_enabled: false,
  is_multiseat_license: false,
  quantity_remaining: null,
  recurrences: null,
  pwyw: null,
  ppp_details: null,
  native_type: "digital",
  ...extra,
});

const selection = (extra: Partial<PriceSelection> = {}): PriceSelection => ({
  rent: false,
  optionId: null,
  price: { error: false, value: null },
  quantity: 1,
  recurrence: null,
  callStartTime: null,
  payInInstallments: false,
  ...extra,
});

describe("initialOptionId", () => {
  const two = product({ options: [option("first"), option("second", { name: "Starter pack" })] });

  it("does not silently pick the first SKU on a multi-option product", () => {
    expect(initialOptionId(two, new URLSearchParams())).toBeNull();
  });

  it("honors an explicit option query param", () => {
    expect(initialOptionId(two, new URLSearchParams("option=second"))).toBe("second");
  });

  it("honors a legacy variant=name query param", () => {
    expect(initialOptionId(two, new URLSearchParams("variant=Starter pack"))).toBe("second");
  });

  it("auto-selects the only in-stock option when there is just one", () => {
    expect(initialOptionId(product({ options: [option("only")] }), new URLSearchParams())).toBe("only");
  });

  it("does not fall back to another SKU when the requested option is sold out", () => {
    const sold = product({
      options: [option("first"), option("second", { quantity_left: 0 })],
    });
    expect(initialOptionId(sold, new URLSearchParams("option=second"))).toBeNull();
  });

  it("keeps the first in-stock amount on a coffee product", () => {
    const coffee = product({ native_type: "coffee", options: [option("one"), option("five")] });
    expect(initialOptionId(coffee, new URLSearchParams())).toBe("one");
  });
});

describe("needsOptionChoice", () => {
  it("relabels the CTA only while a multi-option product has no SKU chosen", () => {
    const two = product({ options: [option("first"), option("second")] });
    expect(needsOptionChoice(two, selection())).toBe(true);
    expect(needsOptionChoice(two, selection({ optionId: "first" }))).toBe(false);
  });

  it("leaves single-option, PWYW, and coffee products on their own label", () => {
    expect(needsOptionChoice(product({ options: [option("only")] }), selection())).toBe(false);
    expect(needsOptionChoice(product({ pwyw: { suggested_price_cents: 500 } }), selection())).toBe(false);
    expect(
      needsOptionChoice(product({ native_type: "coffee", options: [option("first"), option("second")] }), selection()),
    ).toBe(false);
  });

  it("does not ask for a choice when the picker has nothing to offer", () => {
    const soldOut = product({ options: [option("first", { quantity_left: 0 }), option("second", { quantity_left: 0 })] });
    expect(needsOptionChoice(soldOut, selection())).toBe(false);
    expect(isSelectionComplete(soldOut, selection())).toBe(true);
  });

  it("does not ask for a choice when no option can be priced for the chosen recurrence", () => {
    const membership = product({ is_tiered_membership: true, options: [option("first"), option("second")] });
    expect(needsOptionChoice(membership, selection())).toBe(true);
    expect(needsOptionChoice(membership, selection({ recurrence: "monthly" }))).toBe(false);
  });
});

describe("isSelectionComplete", () => {
  const two = product({ options: [option("first"), option("second")] });

  it("is incomplete until the buyer picks one of several options", () => {
    expect(isSelectionComplete(two, selection())).toBe(false);
  });

  it("is complete once an option is chosen", () => {
    expect(isSelectionComplete(two, selection({ optionId: "second" }))).toBe(true);
  });

  it("treats a single-option product with that option selected as complete", () => {
    const one = product({ options: [option("only")] });
    expect(isSelectionComplete(one, selection({ optionId: "only" }))).toBe(true);
  });

  it("is incomplete for PWYW until an amount is entered", () => {
    const pwyw = product({ pwyw: { suggested_price_cents: 500 } });
    expect(isSelectionComplete(pwyw, selection())).toBe(false);
    expect(isSelectionComplete(pwyw, selection({ price: { error: false, value: 800 } }))).toBe(true);
  });

  it("does not treat quantity or a default recurrence as an incomplete choice", () => {
    const qty = product({
      options: [option("only")],
      is_quantity_enabled: true,
      recurrences: { default: "monthly", enabled: [{ recurrence: "monthly", price_cents: 500, id: "m" }] },
    });
    expect(isSelectionComplete(qty, selection({ optionId: "only", quantity: 1, recurrence: "monthly" }))).toBe(true);
  });

  it("lets a coffee buyer through on the Other amount", () => {
    const coffee = product({ native_type: "coffee", options: [option("one"), option("five")] });
    expect(isSelectionComplete(coffee, selection({ price: { error: false, value: 10000 } }))).toBe(true);
  });
});
