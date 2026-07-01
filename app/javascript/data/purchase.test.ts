import { describe, expect, it } from "vitest";

import {
  type CardPaymentMethodParams,
  type PaymentRequestPaymentMethodParams,
  type PayPalNativePaymentMethodParams,
  type StripeErrorParams,
} from "$app/data/payment_method_params";
import { getPaymentDetailsSource, type PurchasePaymentMethod } from "$app/data/purchase";

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

const paypalParams: PayPalNativePaymentMethodParams = {
  status: "success",
  type: "paypal-native",
  reusable: false,
  paypal_order_id: "PAY-123",
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
});
