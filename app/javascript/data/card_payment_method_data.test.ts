import { describe, expect, it } from "vitest";

import { cardPaymentMethodParams, paymentElementBillingDetails } from "$app/data/card_payment_method_data";

describe("cardPaymentMethodParams", () => {
  it("maps a Stripe card PaymentMethod into the existing card params payload", () => {
    const result = cardPaymentMethodParams({
      id: "pm_123",
      card: { country: "US" },
    });

    expect(result).toEqual({
      status: "success",
      type: "card",
      reusable: false,
      stripe_payment_method_id: "pm_123",
      card_country: "US",
      card_country_source: "stripe",
    });
  });

  it("keeps card_country null when Stripe does not return card country", () => {
    const result = cardPaymentMethodParams({
      id: "pm_123",
      card: null,
    });

    expect(result.card_country).toBeNull();
  });
});

describe("paymentElementBillingDetails", () => {
  it("includes billing details for fields disabled in the Payment Element", () => {
    expect(
      paymentElementBillingDetails({
        email: "buyer@example.com",
        fullName: "Buyer Name",
        zipCode: "10001",
        country: "US",
        state: "NY",
        city: "New York",
        address: "123 Main St",
      }),
    ).toEqual({
      email: "buyer@example.com",
      name: "Buyer Name",
      phone: null,
      address: {
        city: "New York",
        country: "US",
        line1: "123 Main St",
        line2: null,
        postal_code: "10001",
        state: "NY",
      },
    });
  });
});
