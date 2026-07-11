// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, type PaymentElementConfig } from "$app/components/Checkout/payment";
import { PaymentElementInput, type PaymentElementController } from "$app/components/Checkout/PaymentElementInput";

const elementsMounts = vi.hoisted<{ currencies: string[]; amounts: (number | undefined)[]; unmounts: number }>(() => ({
  currencies: [],
  amounts: [],
  unmounts: 0,
}));

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
    PaymentElement: ({ onReady }: { onReady: () => void }) => {
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
});
