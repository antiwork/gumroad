import { describe, expect, it } from "vitest";

import {
  type CardPaymentMethodParams,
  type PaymentRequestPaymentMethodParams,
  type ReusablePayPalNativePaymentMethodParams,
  type StripeErrorParams,
} from "$app/data/payment_method_params";
import {
  createPurchasesRequestData,
  getPaymentDetailsSource,
  type PurchasePaymentMethod,
  type StartCartPurchaseRequestPayload,
} from "$app/data/purchase";

const cardParams: CardPaymentMethodParams = {
  status: "success",
  type: "card",
  reusable: false,
  stripe_payment_method_id: "pm_123",
  card_country: "US",
  card_country_source: "stripe",
};

const paymentRequestParams: PaymentRequestPaymentMethodParams = {
  status: "success",
  type: "payment-request",
  reusable: false,
  stripe_payment_method_id: "pm_456",
  card_country: "US",
  card_country_source: "stripe",
  email: "buyer@example.com",
  zip_code: "10001",
  wallet_type: "apple_pay",
};

const paypalParams: ReusablePayPalNativePaymentMethodParams = {
  status: "success",
  type: "paypal-native",
  reusable: true,
  billingToken: "BA-TOKEN",
  billing_agreement_id: "BA-123",
  visual: "buyer@example.com",
  card_country: "US",
};

const stripeErrorParams: StripeErrorParams = {
  status: "error",
  stripe_error: { type: "validation_error", message: "Card details are incomplete." },
};

const cardPaymentMethod: PurchasePaymentMethod = {
  type: "new",
  cardParamsResult: { type: "cc", cardParams, keepOnFile: false, zipCode: null },
};

describe("getPaymentDetailsSource", () => {
  it("reports payment_element for a new card collected via the Payment Element", () => {
    expect(getPaymentDetailsSource(cardPaymentMethod, true)).toBe("payment_element");
  });

  it("reports card_element for a new card collected via the CardElement", () => {
    expect(getPaymentDetailsSource(cardPaymentMethod, false)).toBe("card_element");
  });

  it("reports payment_request for a wallet payment regardless of the element flag", () => {
    const walletPaymentMethod: PurchasePaymentMethod = {
      type: "new",
      cardParamsResult: { type: "cc-payment-request", cardParams: paymentRequestParams },
    };
    expect(getPaymentDetailsSource(walletPaymentMethod, true)).toBe("payment_request");
  });

  it("reports saved_payment_method for a stored card", () => {
    expect(getPaymentDetailsSource({ type: "saved" }, false)).toBe("saved_payment_method");
  });

  it("reports the element surface for a failed card creation so failed attempts are still recorded", () => {
    const erroredPaymentMethod: PurchasePaymentMethod = {
      type: "new",
      cardParamsResult: { type: "error", cardParams: stripeErrorParams },
    };
    expect(getPaymentDetailsSource(erroredPaymentMethod, true)).toBe("payment_element");
    expect(getPaymentDetailsSource(erroredPaymentMethod, false)).toBe("card_element");
  });

  it("reports nothing for PayPal, which is outside the Stripe payment-flow dimensions", () => {
    const paypalPaymentMethod: PurchasePaymentMethod = {
      type: "new",
      cardParamsResult: { type: "paypal", cardParams: paypalParams, keepOnFile: false },
    };
    expect(getPaymentDetailsSource(paypalPaymentMethod, false)).toBeNull();
  });

  it("reports nothing when there is no applicable payment method", () => {
    expect(getPaymentDetailsSource({ type: "not-applicable" }, true)).toBeNull();
  });

  it("reports payment_element for a client-confirm card, which always uses the Payment Element", () => {
    const clientConfirmPaymentMethod: PurchasePaymentMethod = {
      type: "payment-element-client-confirm",
      confirmationTokenId: "ctoken_123",
      cardCountry: "US",
      walletType: null,
      mountCurrency: "usd",
      methodListToken: null,
      selectedMethodType: "card",
    };
    expect(getPaymentDetailsSource(clientConfirmPaymentMethod, true)).toBe("payment_element");
    expect(getPaymentDetailsSource(clientConfirmPaymentMethod, false)).toBe("payment_element");
  });
});

describe("createPurchasesRequestData wallet_type threading", () => {
  const payloadWith = (paymentMethod: PurchasePaymentMethod): StartCartPurchaseRequestPayload => ({
    paymentMethod,
    email: "buyer@example.com",
    fullName: "Buyer",
    zipCode: "10001",
    state: "NY",
    shippingInfo: null,
    taxCountryElection: null,
    vatId: null,
    giftInfo: null,
    eventAttributes: { plugins: null, friend: null, url_parameters: null, locale: "en-US" },
    lineItems: [],
    recaptchaResponse: null,
    usedStripePaymentElement: true,
    buyerCurrencyQuote: null,
  });

  it("sends wallet_type for a wallet that paid through the server-confirm Payment Element", () => {
    const data = createPurchasesRequestData(
      payloadWith({
        type: "new",
        cardParamsResult: {
          type: "cc",
          keepOnFile: false,
          zipCode: null,
          cardParams: {
            ...cardParams,
            wallet: { type: "apple_pay", billingAddress: { country: "US", postal_code: "10001", state: "NY" } },
          },
        },
      }),
      {},
    );

    expect(data.wallet_type).toBe("apple_pay");
    expect(data.payment_details_source).toBe("payment_element");
  });

  it("sends wallet_type for a wallet that paid through the client-confirm lane", () => {
    const data = createPurchasesRequestData(
      payloadWith({
        type: "payment-element-client-confirm",
        confirmationTokenId: "ctoken_123",
        cardCountry: "US",
        walletType: "google_pay",
        mountCurrency: "usd",
        methodListToken: null,
        selectedMethodType: "card",
      }),
      {},
    );

    expect(data.wallet_type).toBe("google_pay");
    expect(data.payment_details_source).toBe("payment_element");
  });

  // The token never leaving the browser silently re-enables gumroad-private#1528, so both the
  // presence and the absence branch are pinned.
  it("sends the mounted method-list token on the client-confirm lane", () => {
    const data = createPurchasesRequestData(
      payloadWith({
        type: "payment-element-client-confirm",
        confirmationTokenId: "ctoken_123",
        cardCountry: "GR",
        walletType: null,
        mountCurrency: "usd",
        methodListToken: "signed-method-list-token",
        selectedMethodType: "card",
      }),
      {},
    );

    expect(data.payment_method_list_token).toBe("signed-method-list-token");
    expect(data.payment_element_mount_currency).toBe("usd");
  });

  it("sends no method-list token when the page mounted without one", () => {
    const data = createPurchasesRequestData(
      payloadWith({
        type: "payment-element-client-confirm",
        confirmationTokenId: "ctoken_123",
        cardCountry: "GR",
        walletType: null,
        mountCurrency: "usd",
        methodListToken: null,
        selectedMethodType: "card",
      }),
      {},
    );

    expect(data.payment_method_list_token).toBeUndefined();
  });

  it("sends no wallet_type for a plain card through the Payment Element", () => {
    const data = createPurchasesRequestData(
      payloadWith({ type: "new", cardParamsResult: { type: "cc", cardParams, keepOnFile: false, zipCode: null } }),
      {},
    );

    expect(data).not.toHaveProperty("wallet_type");
  });

  // Buyer-currency presentment: an eligible wallet purchase must carry the quote token, or the
  // charge silently falls back to canonical USD and the buyer is charged a total that isn't the
  // one their wallet sheet showed. Pinned per lane because the two lanes build their params
  // through different branches of createPurchasesRequestData.
  describe("with a buyer-currency quote", () => {
    const walletPayloadWithQuote = (paymentMethod: PurchasePaymentMethod) => ({
      ...payloadWith(paymentMethod),
      buyerCurrencyQuote: "quote-token-abc",
    });

    it("sends the quote token alongside a server-confirm element wallet payment", () => {
      const data = createPurchasesRequestData(
        walletPayloadWithQuote({
          type: "new",
          cardParamsResult: {
            type: "cc",
            keepOnFile: false,
            zipCode: null,
            cardParams: {
              ...cardParams,
              wallet: { type: "apple_pay", billingAddress: { country: "US", postal_code: "10001", state: "NY" } },
            },
          },
        }),
        {},
      );

      expect(data.buyer_currency_quote).toBe("quote-token-abc");
      expect(data.wallet_type).toBe("apple_pay");
      expect(data.payment_details_source).toBe("payment_element");
    });

    it("sends the quote token alongside a client-confirm wallet payment", () => {
      const data = createPurchasesRequestData(
        walletPayloadWithQuote({
          type: "payment-element-client-confirm",
          confirmationTokenId: "ctoken_123",
          cardCountry: "US",
          walletType: "google_pay",
          mountCurrency: "usd",
          methodListToken: null,
          selectedMethodType: "card",
        }),
        {},
      );

      expect(data.buyer_currency_quote).toBe("quote-token-abc");
      expect(data.wallet_type).toBe("google_pay");
      expect(data.payment_details_source).toBe("payment_element");
    });
  });
});
