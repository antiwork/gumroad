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
  walletSelected: false,
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

    expect(result).toEqual({ status: "success", confirmationTokenId: "ctoken_123", cardCountry: "US", wallet: null });
  });

  it("reports a null card country when the previewed method is not a card", async () => {
    const stripe = stripeWith(
      vi.fn().mockResolvedValue({
        confirmationToken: { id: "ctoken_456", payment_method_preview: { type: "sepa_debit" } },
      }),
    );

    const result = await createPaymentElementConfirmationToken(cardData(stripe, submitOk()));

    expect(result).toEqual({ status: "success", confirmationTokenId: "ctoken_456", cardCountry: null, wallet: null });
  });

  it("skips the checkout-form billing_details override and reports wallet details for a wallet submission", async () => {
    const createConfirmationToken = vi.fn().mockResolvedValue({
      confirmationToken: {
        id: "ctoken_789",
        payment_method_preview: {
          card: { country: "CA", wallet: { type: "apple_pay" } },
          billing_details: { address: { country: "CA", postal_code: "H2X 1Y4", state: "QC" } },
        },
      },
    });
    const elements = submitOk();

    const result = await createPaymentElementConfirmationToken({
      ...cardData(stripeWith(createConfirmationToken), elements),
      walletSelected: true,
    });

    // The wallet sheet's billing details must survive; the checkout form override is omitted.
    expect(createConfirmationToken).toHaveBeenCalledWith({ elements });
    expect(result).toEqual({
      status: "success",
      confirmationTokenId: "ctoken_789",
      cardCountry: "CA",
      wallet: { type: "apple_pay", billingAddress: { country: "CA", postal_code: "H2X 1Y4", state: "QC" } },
    });
  });

  it("treats a Link card-passthrough payment as a card, not a wallet", async () => {
    // Link is enabled on the element independently of the payment_element_wallets flag and mints
    // card PaymentMethods carrying card.wallet.type = "link". Link buyers fill in the Gumroad
    // form like any card buyer, so the form's billing details must be applied and no wallet
    // details reported.
    const createConfirmationToken = vi.fn().mockResolvedValue({
      confirmationToken: {
        id: "ctoken_link",
        payment_method_preview: {
          card: { country: "US", wallet: { type: "link" } },
          billing_details: { address: { country: "US", postal_code: "94103", state: "CA" } },
        },
      },
    });
    const elements = submitOk();

    const result = await createPaymentElementConfirmationToken(cardData(stripeWith(createConfirmationToken), elements));

    expect(createConfirmationToken).toHaveBeenCalledWith({
      elements,
      params: { payment_method_data: { billing_details: expect.any(Object) } },
    });
    expect(result).toEqual({ status: "success", confirmationTokenId: "ctoken_link", cardCountry: "US", wallet: null });
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
