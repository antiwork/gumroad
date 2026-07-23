import { describe, expect, it } from "vitest";

import {
  type CardPaymentMethodParams,
  serializeCardParamsIntoQueryParamsObject,
} from "$app/data/payment_method_params";

// Regression test for the element-full UPI checkout: `wallet` and `elementBillingAddress` are
// client-side checkout context (tax location and the wallet type reported with the purchase).
// The account and subscription endpoints fed by this serializer have no contract for them, and
// a nested unknown object fails their parameter validation — so the serializer must strip them.
describe("serializeCardParamsIntoQueryParamsObject", () => {
  const baseCardParams: CardPaymentMethodParams = {
    status: "success",
    type: "card",
    reusable: false,
    stripe_payment_method_id: "pm_123",
    card_country: "IN",
    card_country_source: "stripe",
  };

  it("strips client-only wallet and elementBillingAddress fields from card params", () => {
    const serialized = serializeCardParamsIntoQueryParamsObject({
      ...baseCardParams,
      wallet: { type: "apple_pay", billingAddress: { country: "US", postal_code: "10001", state: "NY" } },
      elementBillingAddress: { country: "IN", postal_code: "560001", state: "KA" },
    });

    expect(serialized).not.toHaveProperty("wallet");
    expect(serialized).not.toHaveProperty("elementBillingAddress");
    expect(serialized).not.toHaveProperty("status");
    expect(serialized).not.toHaveProperty("type");
    expect(serialized).not.toHaveProperty("reusable");
    expect(serialized.stripe_payment_method_id).toBe("pm_123");
    expect(serialized.card_country).toBe("IN");
  });

  it("keeps the remaining fields intact when the client-only fields are absent", () => {
    const serialized = serializeCardParamsIntoQueryParamsObject(baseCardParams);

    expect(serialized).toEqual({
      stripe_payment_method_id: "pm_123",
      card_country: "IN",
      card_country_source: "stripe",
    });
  });
});
