// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, type PaymentElementConfig } from "$app/components/Checkout/payment";
import { PaymentElementInput, type PaymentElementController } from "$app/components/Checkout/PaymentElementInput";

const elementsMounts = vi.hoisted<{ currencies: string[]; amounts: (number | undefined)[]; unmounts: number }>(() => ({
  currencies: [],
  amounts: [],
  unmounts: 0,
}));

// Captures the options the PaymentElement was last rendered with, plus its onChange handler so
// tests can simulate the buyer selecting a payment-method row inside the element.
const paymentElementRender = vi.hoisted<{
  options: { fields?: { billingDetails?: unknown } } | null;
  onChange: ((event: { value: { type: string }; complete: boolean; empty: boolean }) => void) | null;
  onFocus: (() => void) | null;
}>(() => ({ options: null, onChange: null, onFocus: null }));

vi.mock("@stripe/react-stripe-js", async () => {
  const React = await import("react");
  const elements = { update: vi.fn() };
  const stripe = {};

  return {
    Elements: ({
      children,
      options,
    }: {
      children: React.ReactNode;
      options: { currency: string; amount?: number };
    }) => {
      React.useEffect(() => {
        elementsMounts.currencies.push(options.currency);
        elementsMounts.amounts.push(options.amount);
        return () => {
          elementsMounts.unmounts += 1;
        };
      }, []);
      return children;
    },
    PaymentElement: ({
      onReady,
      options,
      onChange,
      onFocus,
    }: {
      onReady: () => void;
      options: { fields?: { billingDetails?: unknown } };
      onChange?: (event: { value: { type: string }; complete: boolean; empty: boolean }) => void;
      onFocus?: () => void;
    }) => {
      paymentElementRender.options = options;
      paymentElementRender.onChange = onChange ?? null;
      paymentElementRender.onFocus = onFocus ?? null;
      React.useEffect(onReady, [onReady]);
      return null;
    },
    useElements: () => elements,
    useStripe: () => stripe,
  };
});

vi.mock("$app/utils/stripe_loader", () => ({ getCheckoutStripeInstance: vi.fn() }));
vi.mock("$app/utils/styles", () => ({ getCssVariable: () => "0 0 0" }));
vi.mock("$app/components/DesignSettings", () => ({ useFont: () => ({ name: "Inter", url: "inter.woff2" }) }));
vi.mock("$app/components/LoadingSpinner", () => ({ LoadingSpinner: () => null }));
vi.mock("$app/components/ui/Fieldset", () => ({
  Fieldset: ({ children }: { children: React.ReactNode }) => children,
}));

const elementsOptions: PaymentElementConfig = {
  stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
  currency: "usd",
  buyer_currency_presentment: true,
  payment_method_types: ["card"],
  payment_method_creation: "manual",
  stripe_link_enabled: true,
};

const props = {
  elementsOptions,
  walletsEnabled: false,
  disabled: false,
  defaultEmail: "buyer@example.com",
  defaultName: "Buyer",
  invalid: false,
  onReady: vi.fn<(controller: PaymentElementController | null) => void>(),
};

describe("PaymentElementInput", () => {
  beforeEach(() => {
    elementsMounts.currencies = [];
    elementsMounts.amounts = [];
    elementsMounts.unmounts = 0;
    props.onReady.mockClear();
  });

  afterEach(cleanup);

  it("keeps the mounted currency while a surcharge refresh is in flight", () => {
    const { rerender } = render(<PaymentElementInput {...props} amount={1_625} mountCurrency="cad" />);

    expect(elementsMounts.currencies).toEqual(["cad"]);

    rerender(<PaymentElementInput {...props} amount={null} mountCurrency={null} />);
    rerender(<PaymentElementInput {...props} amount={1_750} mountCurrency="cad" />);

    expect(elementsMounts.currencies).toEqual(["cad"]);
    expect(elementsMounts.unmounts).toBe(0);
  });

  it("remounts when the currency genuinely changes", () => {
    const { rerender } = render(<PaymentElementInput {...props} amount={1_625} mountCurrency="cad" />);

    // A definite canonical transition (loaded surcharges without a quote, or the buyer opting
    // to save the card) must still remount: Stripe cannot change the currency of a live
    // element, and the sheet must not keep presenting a currency the buyer won't be charged.
    rerender(<PaymentElementInput {...props} amount={1_300} mountCurrency="usd" />);

    expect(elementsMounts.currencies).toEqual(["cad", "usd"]);
    // The new Elements instance must be created with the amount that belongs to the new
    // currency, not the amount captured at the provider's first mount — 1625 is a CAD
    // total, and reusing it for the USD mount would send a wrong (and wrongly-denominated)
    // amount in the creation request.
    expect(elementsMounts.amounts).toEqual([1_625, 1_300]);
    expect(elementsMounts.unmounts).toBe(1);
  });

  it("relaxes billingDetails collection to auto while a wallet row is selected, and restores never on card", () => {
    render(<PaymentElementInput {...props} walletsEnabled amount={1_000} mountCurrency="usd" />);

    // Card is the default selection: every billing-details field is pinned to "never" because
    // checkout's own form collects them and tokenization passes them explicitly.
    expect(paymentElementRender.options?.fields).toEqual({
      billingDetails: {
        name: "never",
        email: "never",
        phone: "never",
        address: {
          country: "never",
          postalCode: "never",
          state: "never",
          city: "never",
          line1: "never",
          line2: "never",
        },
      },
    });

    // The buyer selects the Apple Pay row: the wallet sheet supplies billing details and
    // tokenization passes none, so the fields must flip to "auto" — with "never" still in place
    // Stripe rejects the wallet tokenization with an IntegrationError.
    act(() => paymentElementRender.onChange?.({ value: { type: "apple_pay" }, complete: false, empty: false }));
    expect(paymentElementRender.options?.fields).toEqual({ billingDetails: "auto" });

    // Back to the card row: the "never" pinning (and with it the requirement to pass the
    // checkout form's billing details) must return.
    act(() => paymentElementRender.onChange?.({ value: { type: "card" }, complete: false, empty: false }));
    expect(paymentElementRender.options?.fields).toEqual({
      billingDetails: {
        name: "never",
        email: "never",
        phone: "never",
        address: {
          country: "never",
          postalCode: "never",
          state: "never",
          city: "never",
          line1: "never",
          line2: "never",
        },
      },
    });
  });

  it("forwards element focus to onFocus, alongside the Link-prefill touch tracking", () => {
    // The flat payment-methods layout (payment_element_wallets) re-selects the card/wallet lane
    // from PayPal when the buyer interacts with the element. Clicks inside the element's iframe
    // never reach the surrounding DOM, so PaymentForm relies on this callback being wired
    // through to the underlying PaymentElement's focus event.
    const onFocus = vi.fn();
    render(<PaymentElementInput {...props} onFocus={onFocus} amount={1_000} mountCurrency="usd" />);

    act(() => paymentElementRender.onFocus?.());
    expect(onFocus).toHaveBeenCalledTimes(1);
  });
});
