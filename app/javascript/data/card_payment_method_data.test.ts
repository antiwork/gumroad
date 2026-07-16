import type { Stripe, StripeElements } from "@stripe/stripe-js";
import { describe, expect, it, vi } from "vitest";

import {
  cardPaymentMethodParams,
  createPaymentElementConfirmationToken,
  paymentElementBillingDetails,
  preparePaymentElementPaymentMethodData,
} from "$app/data/card_payment_method_data";

// Shared fixture for the pendingSubmit tests below: a minimal Stripe + Elements pair (built the
// same way as payment_element_client_confirm.test.ts — Object.create keeps eslint's no-type-
// assertion rule happy) where we can observe whether tokenization called elements.submit()
// itself or reused the click-time promise it was handed.
const buildStripeFixture = () => {
  const submit = vi.fn().mockResolvedValue({ error: undefined });
  const elements: StripeElements = Object.create(null);
  elements.submit = submit;
  const stripe: Stripe = Object.create(null);
  stripe.createPaymentMethod = vi.fn().mockResolvedValue({
    paymentMethod: { id: "pm_wallet", card: { country: "US" }, type: "card" },
  });
  stripe.createConfirmationToken = vi.fn().mockResolvedValue({
    confirmationToken: { id: "ctoken_wallet", payment_method_preview: { card: { country: "US" }, type: "card" } },
  });
  return { stripe, elements, submit };
};

const walletCardData = (stripe: Stripe, elements: StripeElements) => ({
  stripe,
  elements,
  email: "buyer@example.com",
  fullName: "Buyer Name",
  zipCode: "10001",
  country: "US",
  state: "NY",
  city: "New York",
  address: "123 Main St",
  walletSelected: true,
});

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

describe("pendingSubmit reuse (wallet click-time elements.submit)", () => {
  // Safari only opens the Apple Pay sheet inside the click's user-activation window, so for
  // wallet payments the pay-button click calls elements.submit() itself and hands tokenization
  // the in-flight promise. Tokenization must await THAT promise and never submit a second time
  // (a second submit is what voids the activation and makes Stripe refuse to open the sheet).
  it("preparePaymentElementPaymentMethodData awaits the pending submit instead of re-submitting", async () => {
    const { stripe, elements, submit } = buildStripeFixture();
    const pendingSubmit = Promise.resolve({});

    const result = await preparePaymentElementPaymentMethodData({
      ...walletCardData(stripe, elements),
      pendingSubmit,
    });

    expect(submit).not.toHaveBeenCalled();
    expect(result.status).toBe("success");
  });

  it("preparePaymentElementPaymentMethodData submits itself when no pending submit exists", async () => {
    const { stripe, elements, submit } = buildStripeFixture();

    const result = await preparePaymentElementPaymentMethodData(walletCardData(stripe, elements));

    expect(submit).toHaveBeenCalledTimes(1);
    expect(result.status).toBe("success");
  });

  it("preparePaymentElementPaymentMethodData surfaces an error from the pending submit", async () => {
    const { stripe, elements, submit } = buildStripeFixture();
    const stripeError = { type: "validation_error" as const, message: "incomplete" };
    const pendingSubmit = Promise.resolve({ error: stripeError });

    const result = await preparePaymentElementPaymentMethodData({
      ...walletCardData(stripe, elements),
      pendingSubmit,
    });

    expect(result).toEqual({ status: "error", stripe_error: stripeError });
    expect(submit).not.toHaveBeenCalled();
  });

  it("createPaymentElementConfirmationToken awaits the pending submit instead of re-submitting", async () => {
    const { stripe, elements, submit } = buildStripeFixture();
    const pendingSubmit = Promise.resolve({});

    const result = await createPaymentElementConfirmationToken({
      ...walletCardData(stripe, elements),
      pendingSubmit,
    });

    expect(submit).not.toHaveBeenCalled();
    expect(result.status).toBe("success");
  });

  it("createPaymentElementConfirmationToken submits itself when no pending submit exists", async () => {
    const { stripe, elements, submit } = buildStripeFixture();

    const result = await createPaymentElementConfirmationToken(walletCardData(stripe, elements));

    expect(submit).toHaveBeenCalledTimes(1);
    expect(result.status).toBe("success");
  });
});
