// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { GiftForm } from "$app/components/Checkout/GiftForm";
import { StateContext, type CheckoutPaymentConfig, type State } from "$app/components/Checkout/payment";

const cardElementConfig: CheckoutPaymentConfig = {
  integration: "card_element",
  fallback_reason: "not_checkout",
  disable_wallets: false,
  request_apple_pay_merchant_tokens: false,
  payment_element_wallets: false,
  flat_payment_methods: false,
  elements_options: null,
};

const state = (overrides: Partial<State> = {}): State => ({
  products: [
    {
      permalink: "product-a",
      name: "Product A",
      creator: { id: "seller-a", name: "Seller A", profile_url: "", avatar_url: "" },
      quantity: 1,
      price: 1000,
      payInInstallments: false,
      requireShipping: false,
      customFields: [],
      bundleProductCustomFields: [],
      supportsPaypal: null,
      testPurchase: false,
      requirePayment: true,
      hasFreeTrial: false,
      hasTippingEnabled: false,
      isPreorder: false,
      canGift: true,
      nativeType: "digital",
      recurrence: null,
      shippableCountryCodes: [],
    },
  ],
  countries: { US: "United States" },
  usStates: [],
  caProvinces: [],
  tipOptions: [],
  country: "US",
  email: "buyer@example.com",
  vatId: "",
  fullName: "",
  address: "",
  city: "",
  state: "",
  zipCode: "",
  buyerCurrency: null,
  buyerCurrencyRemint: null,
  unavailableBuyerCurrency: null,
  saveAddress: false,
  gift: null,
  customFieldValues: {},
  surcharges: { type: "pending" },
  availablePaymentMethods: [],
  paymentMethod: "card",
  paymentElementType: "card",
  willSaveCard: false,
  usingSavedCard: false,
  savedCreditCard: null,
  checkoutPayment: cardElementConfig,
  checkoutPaymentStale: false,
  resumeSubmitAfterCheckoutPayment: false,
  validationFailedCount: 0,
  status: { type: "input", errors: new Set() },
  recaptchaKey: null,
  recaptchaScoreBased: false,
  recaptchaChallengeKey: null,
  paypalClientId: "",
  tip: { type: "percentage", percentage: 0 },
  emailTypoSuggestion: null,
  acknowledgedEmails: new Set(),
  requireEmailTypoAcknowledgment: false,
  ...overrides,
});

afterEach(() => cleanup());

describe("GiftForm", () => {
  it("does not show the anonymity switch until gifting is on", () => {
    render(
      <StateContext.Provider value={[state(), vi.fn()]}>
        <GiftForm isMembership={false} />
      </StateContext.Provider>,
    );

    expect(screen.queryByText("Stay anonymous to the recipient")).toBeNull();
  });

  it("lets the buyer hide their identity from the recipient", () => {
    const dispatch = vi.fn();
    render(
      <StateContext.Provider
        value={[
          state({ gift: { type: "normal", email: "giftee@example.com", note: "", hideGifter: false } }),
          dispatch,
        ]}
      >
        <GiftForm isMembership={false} />
      </StateContext.Provider>,
    );

    expect(screen.getByText("Stay anonymous to the recipient")).not.toBeNull();
    const anonymitySwitch = screen.getAllByRole("switch").at(1);
    expect(anonymitySwitch).toBeInstanceOf(HTMLElement);
    if (!(anonymitySwitch instanceof HTMLElement)) return;
    fireEvent.click(anonymitySwitch);

    expect(dispatch).toHaveBeenCalledWith({
      type: "set-value",
      gift: { type: "normal", email: "giftee@example.com", note: "", hideGifter: true },
    });
  });
});
