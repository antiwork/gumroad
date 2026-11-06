// @vitest-environment happy-dom
import { describe, it, expect } from "vitest";

import { buildDiscountPayload, DiscountPayload } from "$app/data/offer_code";

const payload: DiscountPayload = {
  name: "Launch",
  code: "launch",
  discount: { type: "percent", value: 10 },
  selectedProductIds: ["p1"],
  selectedOptionIds: [],
  excludedProductIds: [],
  universal: false,
  currencyCode: "usd",
  maxQuantity: null,
  validAt: null,
  expiresAt: null,
  minimumQuantity: null,
  durationInBillingCycles: null,
  minimumAmount: null,
  oncePerCart: false,
  existingCustomersOnly: true,
  newCustomersOnly: false,
  autoApply: false,
  saleLabel: null,
  ownershipProductIds: ["owned-product"],
  ownershipOptionIds: ["owned-option"],
  ownershipDurationTiers: null,
};

describe("buildDiscountPayload", () => {
  it("sends the options the buyer must have already purchased", () => {
    const built = buildDiscountPayload(payload);

    expect(built.ownership_option_ids).toEqual(["owned-option"]);
    expect(built.ownership_product_ids).toEqual(["owned-product"]);
  });

  it("clears the ownership requirement when the code is not limited to existing customers", () => {
    const built = buildDiscountPayload({ ...payload, existingCustomersOnly: false });

    expect(built.ownership_option_ids).toEqual([]);
    expect(built.ownership_product_ids).toEqual([]);
  });
});
