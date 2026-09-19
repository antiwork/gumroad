import { describe, expect, it } from "vitest";

import type { Option, PriceSelection, Product } from "$app/components/Product/ConfigurationSelector";
import { initialOptionId, isSelectionComplete } from "$app/components/Product/purchaseReadiness";

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
});
