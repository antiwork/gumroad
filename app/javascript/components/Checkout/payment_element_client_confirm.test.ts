import type { Stripe, StripeElements } from "@stripe/stripe-js";
import { describe, expect, it, vi } from "vitest";

import { createPaymentElementConfirmationToken, type PaymentElementCardData } from "$app/data/card_payment_method_data";

const stripeWith = (createConfirmationToken: Stripe["createConfirmationToken"]): Stripe => {
  const stripe: Stripe = Object.create(null);
  stripe.createConfirmationToken = createConfirmationToken;
  return stripe;
};

const elementsWith = (submit: StripeElements["submit"]): StripeElements => {
  const elements: StripeElements = Object.create(null);
  elements.submit = submit;
  return elements;
};

const cardData = (stripe: Stripe, elements: StripeElements): PaymentElementCardData => ({
  stripe,
  elements,
  email: "buyer@example.com",
  fullName: "Buyer",
  zipCode: "10001",
  country: "US",
  state: "NY",
  city: "New York",
  address: "1 Test St",
});

const submitOk = () => elementsWith(vi.fn().mockResolvedValue({ error: undefined }));

describe("createPaymentElementConfirmationToken", () => {
  it("mints a ConfirmationToken and reports the previewed card country", async () => {
    const stripe = stripeWith(
      vi.fn().mockResolvedValue({
        confirmationToken: { id: "ctoken_123", payment_method_preview: { card: { country: "US" } } },
      }),
    );

    const result = await createPaymentElementConfirmationToken(cardData(stripe, submitOk()));

    expect(result).toEqual({ status: "success", confirmationTokenId: "ctoken_123", cardCountry: "US" });
  });

  it("reports a null card country when the previewed method is not a card", async () => {
    const stripe = stripeWith(
      vi.fn().mockResolvedValue({
        confirmationToken: { id: "ctoken_456", payment_method_preview: { type: "sepa_debit" } },
      }),
    );

    const result = await createPaymentElementConfirmationToken(cardData(stripe, submitOk()));

    expect(result).toEqual({ status: "success", confirmationTokenId: "ctoken_456", cardCountry: null });
  });

  it("surfaces a validation error from elements.submit without minting a token", async () => {
    const createConfirmationToken = vi.fn();
    const elements = elementsWith(
      vi.fn().mockResolvedValue({ error: { type: "validation_error", message: "Incomplete" } }),
    );

    const result = await createPaymentElementConfirmationToken(cardData(stripeWith(createConfirmationToken), elements));

    expect(result).toEqual({ status: "error", stripe_error: { type: "validation_error", message: "Incomplete" } });
    expect(createConfirmationToken).not.toHaveBeenCalled();
  });

  it("surfaces an error from createConfirmationToken", async () => {
    const stripe = stripeWith(
      vi.fn().mockResolvedValue({ error: { type: "card_error", message: "Your card was declined." } }),
    );

    const result = await createPaymentElementConfirmationToken(cardData(stripe, submitOk()));

    expect(result).toEqual({
      status: "error",
      stripe_error: { type: "card_error", message: "Your card was declined." },
    });
  });
});
