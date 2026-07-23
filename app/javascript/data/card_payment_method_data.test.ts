import type { Stripe, StripeElements } from "@stripe/stripe-js";
import { describe, expect, it, vi } from "vitest";

import {
  cardPaymentMethodParams,
  createPaymentElementConfirmationToken,
  paymentElementBillingDetails,
  paymentElementBillingDetailsCollection,
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
  const createConfirmationToken = vi.fn().mockResolvedValue({
    confirmationToken: { id: "ctoken_wallet", payment_method_preview: { card: { country: "US" }, type: "card" } },
  });
  stripe.createConfirmationToken = createConfirmationToken;
  return { stripe, elements, submit, createConfirmationToken };
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
  billingDetailsCollection: "element" as const,
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

describe("paymentElementBillingDetailsCollection", () => {
  it("routes wallets to element, UPI on digital carts to element-full, everything else to form", () => {
    expect(paymentElementBillingDetailsCollection("apple_pay", false)).toBe("element");
    expect(paymentElementBillingDetailsCollection("google_pay", false)).toBe("element");
    expect(paymentElementBillingDetailsCollection("apple_pay", true)).toBe("element");
    // UPI confirms require billing_details.name + a full street address, which the digital
    // checkout form never collects — the element gathers name + address itself
    // (gumroad-private#933)...
    expect(paymentElementBillingDetailsCollection("upi", false)).toBe("element-full");
    // ...but shippable carts already collect a full address in checkout's own form, so nothing
    // extra should be asked for inside the element.
    expect(paymentElementBillingDetailsCollection("upi", true)).toBe("form");
    expect(paymentElementBillingDetailsCollection("card", false)).toBe("form");
    expect(paymentElementBillingDetailsCollection("link", false)).toBe("form");
    expect(paymentElementBillingDetailsCollection("ideal", false)).toBe("form");
  });
});

describe("element-collected billing details (wallets, UPI)", () => {
  it("createPaymentElementConfirmationToken skips the checkout-form billing override when the element collects billing details", async () => {
    const { stripe, elements, createConfirmationToken } = buildStripeFixture();

    const result = await createPaymentElementConfirmationToken(walletCardData(stripe, elements));

    expect(result.status).toBe("success");
    // No params at all: passing the form's billing_details would clobber what the wallet sheet
    // collected.
    expect(createConfirmationToken).toHaveBeenCalledWith({ elements });
  });

  it("createPaymentElementConfirmationToken passes only the form's email for element-full collection (UPI)", async () => {
    const { stripe, elements, createConfirmationToken } = buildStripeFixture();

    const result = await createPaymentElementConfirmationToken({
      ...walletCardData(stripe, elements),
      billingDetailsCollection: "element-full",
    });

    expect(result.status).toBe("success");
    // The element's pane collected the name and the full street address itself (checkout's own
    // fields are hidden for this selection) — only the email, which checkout's form still owns,
    // is passed. No name/country/address overrides: they would clobber what the buyer typed
    // into the pane.
    expect(createConfirmationToken).toHaveBeenCalledWith({
      elements,
      params: {
        payment_method_data: {
          billing_details: { email: "buyer@example.com", phone: null },
        },
      },
    });
  });

  it("createPaymentElementConfirmationToken reports the pane-collected billing address for element-full collection (UPI)", async () => {
    const { stripe, elements } = buildStripeFixture();
    stripe.createConfirmationToken = vi.fn().mockResolvedValue({
      confirmationToken: {
        id: "ctoken_upi",
        payment_method_preview: {
          type: "upi",
          billing_details: { address: { country: "IN", postal_code: "560001", state: "KA" } },
        },
      },
    });

    const result = await createPaymentElementConfirmationToken({
      ...walletCardData(stripe, elements),
      billingDetailsCollection: "element-full",
    });

    // Checkout adopts this address as the tax location (its own country field is hidden for
    // the selection), mirroring the wallet billing-address path.
    expect(result).toMatchObject({
      status: "success",
      elementBillingAddress: { country: "IN", postal_code: "560001", state: "KA" },
    });
  });

  it("createPaymentElementConfirmationToken reports no element billing address for form collection", async () => {
    const { stripe, elements } = buildStripeFixture();

    const result = await createPaymentElementConfirmationToken(walletCardData(stripe, elements));

    // Wallet/card/form selections keep their existing tax-location sources (the wallet details
    // path and checkout's own form respectively) — the element-address adoption is exclusive
    // to element-full.
    expect(result).toMatchObject({ status: "success", elementBillingAddress: null });
  });

  it("preparePaymentElementPaymentMethodData surfaces the pane-collected billing address for element-full collection (UPI, server-confirm)", async () => {
    const { stripe, elements } = buildStripeFixture();
    stripe.createPaymentMethod = vi.fn().mockResolvedValue({
      paymentMethod: {
        id: "pm_upi",
        type: "upi",
        billing_details: { address: { country: "IN", postal_code: "560001", state: "KA" } },
      },
    });

    const result = await preparePaymentElementPaymentMethodData({
      ...walletCardData(stripe, elements),
      billingDetailsCollection: "element-full",
    });

    // The server-confirm lane must adopt the element's pane address as checkout's tax location
    // too — otherwise the purchase would proceed on the stale GeoIP location, since checkout's
    // own country/ZIP fields are hidden for this selection.
    expect(result).toMatchObject({
      status: "success",
      elementBillingAddress: { country: "IN", postal_code: "560001", state: "KA" },
    });
  });

  it("preparePaymentElementPaymentMethodData omits elementBillingAddress outside element-full collection", async () => {
    const { stripe, elements } = buildStripeFixture();

    const result = await preparePaymentElementPaymentMethodData({
      ...walletCardData(stripe, elements),
      billingDetailsCollection: "form",
    });

    expect(result.status).toBe("success");
    // Omitted entirely (never null) so spreading these params into server requests stays
    // unchanged for card payments — same contract as the `wallet` key.
    expect("elementBillingAddress" in result).toBe(false);
  });

  it("createPaymentElementConfirmationToken passes the checkout form's billing details for card payments", async () => {
    const { stripe, elements, createConfirmationToken } = buildStripeFixture();

    const result = await createPaymentElementConfirmationToken({
      ...walletCardData(stripe, elements),
      billingDetailsCollection: "form",
    });

    expect(result.status).toBe("success");
    expect(createConfirmationToken).toHaveBeenCalledWith({
      elements,
      params: {
        payment_method_data: {
          billing_details: {
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
          },
        },
      },
    });
  });
});
