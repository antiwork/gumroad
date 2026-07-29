// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
  type PaymentElementClientConfirmConfig,
  type PaymentElementConfig,
} from "$app/components/Checkout/payment";
import { PaymentElementInput, type PaymentElementController } from "$app/components/Checkout/PaymentElementInput";

const elementsMounts = vi.hoisted<{
  currencies: string[];
  amounts: (number | undefined)[];
  paymentMethodTypes: (readonly string[] | undefined)[];
  unmounts: number;
}>(() => ({
  currencies: [],
  amounts: [],
  paymentMethodTypes: [],
  unmounts: 0,
}));

// Captures the options the PaymentElement was last rendered with, plus its onChange handler so
// tests can simulate the buyer selecting a payment-method row inside the element.
const paymentElementRender = vi.hoisted<{
  options: {
    fields?: { billingDetails?: unknown };
    defaultValues?: unknown;
    layout?: unknown;
    wallets?: unknown;
  } | null;
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
      options: { currency: string; amount?: number; paymentMethodTypes?: readonly string[] };
    }) => {
      React.useEffect(() => {
        elementsMounts.currencies.push(options.currency);
        elementsMounts.amounts.push(options.amount);
        elementsMounts.paymentMethodTypes.push(options.paymentMethodTypes);
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
  flatLayout: false,
  disabled: false,
  defaultEmail: "buyer@example.com",
  defaultName: "Buyer",
  defaultCountry: "IN",
  hasShippingCart: false,
  invalid: false,
  onReady: vi.fn<(controller: PaymentElementController | null) => void>(),
};

describe("PaymentElementInput", () => {
  beforeEach(() => {
    elementsMounts.currencies = [];
    elementsMounts.amounts = [];
    elementsMounts.paymentMethodTypes = [];
    elementsMounts.unmounts = 0;
    props.onReady.mockClear();
  });

  afterEach(cleanup);

  // The client-confirm lane is the one with a resolver-computed method list (the server-confirm
  // config is pinned to card), so the narrowing tests mount that config.
  const clientConfirmOptions = (paymentMethodTypes: string[]): PaymentElementClientConfirmConfig => ({
    stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
    currency: "usd",
    presentment_amount_cents: null,
    listed_currency_display: null,
    payment_method_types: paymentMethodTypes,
    stripe_link_enabled: true,
    stripe_connect_account_id: null,
  });

  // gumroad-private#1528: Stripe fixes paymentMethodTypes at Elements creation and offers no update
  // path, so a config refresh after mount does NOT reach the live element. #prepare narrows the
  // deferred intent against the reported list, which therefore has to be the list the element was
  // actually created with — reporting the current config would defeat the whole narrowing.
  it("reports the method list the element was created with, and keeps it frozen across a config change", () => {
    const onMountedPaymentMethodTypes = vi.fn<(paymentMethodTypes: readonly string[]) => void>();
    const { rerender } = render(
      <PaymentElementInput
        {...props}
        amount={1_000}
        mountCurrency="usd"
        elementsOptions={clientConfirmOptions(["card", "link"])}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    expect(elementsMounts.paymentMethodTypes).toEqual([["card", "link"]]);
    expect(onMountedPaymentMethodTypes).toHaveBeenLastCalledWith(["card", "link"]);

    // The server now says Klarna is available. The mounted element cannot show it, so the report
    // must not start claiming it either.
    rerender(
      <PaymentElementInput
        {...props}
        amount={1_000}
        mountCurrency="usd"
        elementsOptions={clientConfirmOptions(["card", "link", "klarna"])}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    expect(elementsMounts.paymentMethodTypes).toEqual([["card", "link"]]);
    expect(elementsMounts.unmounts).toBe(0);
    expect(onMountedPaymentMethodTypes).toHaveBeenLastCalledWith(["card", "link"]);
  });

  // A currency change DOES remount Elements, so the new instance's list is the one that counts.
  it("re-reports the method list when a currency change remounts the element", () => {
    const onMountedPaymentMethodTypes = vi.fn<(paymentMethodTypes: readonly string[]) => void>();
    const { rerender } = render(
      <PaymentElementInput
        {...props}
        amount={1_000}
        mountCurrency="usd"
        elementsOptions={clientConfirmOptions(["card", "link"])}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    rerender(
      <PaymentElementInput
        {...props}
        amount={1_625}
        mountCurrency="cad"
        elementsOptions={clientConfirmOptions(["card", "ideal"])}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    expect(elementsMounts.paymentMethodTypes).toEqual([
      ["card", "link"],
      ["card", "ideal"],
    ]);
    expect(onMountedPaymentMethodTypes).toHaveBeenLastCalledWith(["card", "ideal"]);
  });

  // The mode is the other half of the remount key, so it needs the same re-capture as the currency:
  // a mode flip that reused the previous mount's list would report a list the new element does not
  // have. Unreachable while the config is fixed at page load, reachable once it is reloaded after a
  // cart change (antiwork/gumroad#6486).
  it("re-reports the method list when a mode change remounts the element", () => {
    const onMountedPaymentMethodTypes = vi.fn<(paymentMethodTypes: readonly string[]) => void>();
    const { rerender } = render(
      <PaymentElementInput
        {...props}
        amount={1_000}
        mountCurrency="usd"
        elementsOptions={clientConfirmOptions(["card", "link", "klarna"])}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    rerender(
      <PaymentElementInput
        {...props}
        amount={1_000}
        mountCurrency="usd"
        elementsOptions={{ ...elementsOptions, stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT }}
        onMountedPaymentMethodTypes={onMountedPaymentMethodTypes}
      />,
    );

    expect(elementsMounts.paymentMethodTypes).toEqual([["card", "link", "klarna"], ["card"]]);
    expect(elementsMounts.unmounts).toBe(1);
    expect(onMountedPaymentMethodTypes).toHaveBeenLastCalledWith(["card"]);
  });

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
    render(<PaymentElementInput {...props} walletsEnabled flatLayout amount={1_000} mountCurrency="usd" />);

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

  it("has the element collect the street address (not name or email) inside the UPI pane on a digital cart", () => {
    render(<PaymentElementInput {...props} walletsEnabled flatLayout amount={100_000} mountCurrency="inr" />);

    // The buyer selects the UPI row. Stripe requires billing_details.name + a full street
    // address to confirm UPI, and the digital checkout form has no street-address fields — so
    // Stripe's pane collects the address itself (localized + validated) while checkout's
    // Country/ZIP fields hide for the selection (see SharedInputs in PaymentForm.tsx) so
    // nothing is asked for twice. Name and email stay "never": both remain checkout's own
    // fields — moving name into the pane would lose a name typed before switching (the pane
    // only applies defaultValues present when its fields first render — PR #6191 review) —
    // and tokenization passes them alongside (gumroad-private#933).
    act(() => paymentElementRender.onChange?.({ value: { type: "upi" }, complete: false, empty: false }));
    expect(paymentElementRender.options?.fields).toEqual({
      billingDetails: {
        name: "never",
        email: "never",
        phone: "never",
        address: "auto",
      },
    });
  });

  it("prefills the UPI pane's address form with the country checkout already knows", () => {
    render(<PaymentElementInput {...props} walletsEnabled amount={100_000} mountCurrency="inr" />);

    // The GeoIP-detected country and the buyer's known name/email ride along as defaultValues
    // from mount, so the pane's address form opens on the right country's format. (Name and
    // email render nothing in the pane — both fields are pinned to "never" — but Stripe ignores
    // defaults for unrendered fields, so passing them is harmless and keeps Link's email
    // prefill working.)
    act(() => paymentElementRender.onChange?.({ value: { type: "upi" }, complete: false, empty: false }));
    expect(paymentElementRender.options?.defaultValues).toEqual({
      billingDetails: { email: "buyer@example.com", name: "Buyer", address: { country: "IN" } },
    });
  });

  it("keeps tracking a name typed AFTER the buyer touched the element", () => {
    // Regression (PR #6191 review): the buyer clicks into the element (Card row) first, THEN
    // types their name into checkout's Full name field. Link's email prefill deliberately
    // freezes once the element is touched — but the name default must keep tracking the live
    // form value rather than freeze with it.
    vi.useFakeTimers();
    try {
      const { rerender } = render(
        <PaymentElementInput {...props} defaultName="" walletsEnabled amount={100_000} mountCurrency="inr" />,
      );

      // Buyer interacts with the element first — this freezes the Link email prefill.
      act(() => paymentElementRender.onFocus?.());
      // Then types their name into checkout's Full name field.
      rerender(
        <PaymentElementInput
          {...props}
          defaultName="Priya Sharma"
          walletsEnabled
          amount={100_000}
          mountCurrency="inr"
        />,
      );
      act(() => vi.advanceTimersByTime(1_000)); // past the prefill debounce
      // The element's options must carry the just-typed name, not a frozen snapshot.
      act(() => paymentElementRender.onChange?.({ value: { type: "upi" }, complete: false, empty: false }));
      expect(paymentElementRender.options?.defaultValues).toEqual({
        billingDetails: { email: "buyer@example.com", name: "Priya Sharma", address: { country: "IN" } },
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps every UPI billing field on the checkout form for shippable carts", () => {
    render(
      <PaymentElementInput {...props} hasShippingCart walletsEnabled flatLayout amount={100_000} mountCurrency="inr" />,
    );

    // Shippable carts collect the full street address in checkout's shipping form, so the
    // element must not ask for the address a second time — everything stays "never" and
    // tokenization passes the form's values, exactly like a card payment.
    act(() => paymentElementRender.onChange?.({ value: { type: "upi" }, complete: false, empty: false }));
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

  it("reports a null controller when the element unmounts, even mid-UPI-selection", () => {
    // PaymentForm relies on this contract to un-hide its Country/ZIP fields when the buyer
    // switches away from the element while UPI is selected — e.g. clicking "Use saved card"
    // unmounts this whole subtree, and the resulting onReady(null) is what resets the
    // mirrored paymentElementType back to "card" (see handlePaymentElementReady in
    // PaymentForm.tsx). Without the unmount notification the UPI field-hiding would strand.
    const { unmount } = render(<PaymentElementInput {...props} walletsEnabled amount={100_000} mountCurrency="inr" />);

    act(() => paymentElementRender.onChange?.({ value: { type: "upi" }, complete: false, empty: false }));
    expect(props.onReady.mock.lastCall?.[0]).not.toBeNull();

    unmount();
    expect(props.onReady).toHaveBeenLastCalledWith(null);
  });

  it("forwards element focus to onFocus, alongside the Link-prefill touch tracking", () => {
    // The flat payment-methods layout (flat_payment_methods) re-selects the card/wallet lane
    // from PayPal when the buyer interacts with the element. Clicks inside the element's iframe
    // never reach the surrounding DOM, so PaymentForm relies on this callback being wired
    // through to the underlying PaymentElement's focus event.
    const onFocus = vi.fn();
    render(<PaymentElementInput {...props} onFocus={onFocus} amount={1_000} mountCurrency="usd" />);

    act(() => paymentElementRender.onFocus?.());
    expect(onFocus).toHaveBeenCalledTimes(1);
  });

  it("renders the flat accordion with wallets pinned to never when the cart suppresses wallets", () => {
    // The flat layout is decoupled from the wallet rollout: a wallet-suppressed cart (e.g. the
    // buyer-currency presentment lane, disable_wallets) still renders the accordion payment-method
    // list — Apple Pay/Google Pay rows simply never appear.
    render(<PaymentElementInput {...props} flatLayout amount={1_000} mountCurrency="usd" />);

    expect(paymentElementRender.options?.layout).toEqual({
      type: "accordion",
      radios: false,
      spacedAccordionItems: true,
    });
    expect(paymentElementRender.options?.wallets).toEqual({ applePay: "never", googlePay: "never", link: "auto" });
  });

  it("keeps the legacy tabs layout when the flat list is off", () => {
    // The CardElement-adjacent legacy shape: the element is purely an internal card form (tabs
    // layout, tabs hidden by the appearance rules) — the pre-flat-list behavior, byte-identical.
    render(<PaymentElementInput {...props} amount={1_000} mountCurrency="usd" />);

    expect(paymentElementRender.options?.layout).toEqual({ type: "tabs" });
  });
});
