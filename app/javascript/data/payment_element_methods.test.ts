import { describe, expect, it } from "vitest";

import { paymentElementRequiresBillingName } from "$app/data/payment_element_methods";

describe("paymentElementRequiresBillingName", () => {
  it("requires a billing name for the methods Stripe rejects without one", () => {
    expect(paymentElementRequiresBillingName("upi")).toBe(true);
    expect(paymentElementRequiresBillingName("bancontact")).toBe(true);
  });

  it("does not require a billing name for other methods", () => {
    expect(paymentElementRequiresBillingName("card")).toBe(false);
    expect(paymentElementRequiresBillingName("ideal")).toBe(false);
    expect(paymentElementRequiresBillingName("link")).toBe(false);
    expect(paymentElementRequiresBillingName("apple_pay")).toBe(false);
  });

  it("treats an unknown selection as not requiring a name", () => {
    expect(paymentElementRequiresBillingName(null)).toBe(false);
    expect(paymentElementRequiresBillingName(undefined)).toBe(false);
  });
});
