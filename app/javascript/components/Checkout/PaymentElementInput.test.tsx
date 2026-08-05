// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type CheckoutTheme, CheckoutThemeProvider } from "$app/components/Checkout/checkoutTheme";
import { STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT, type PaymentElementConfig } from "$app/components/Checkout/payment";
import { PaymentElementInput, type PaymentElementController } from "$app/components/Checkout/PaymentElementInput";

const elementsMounts = vi.hoisted<{ currencies: string[]; amounts: (number | undefined)[]; unmounts: number }>(() => ({
  currencies: [],
  amounts: [],
  unmounts: 0,
}));

const elementsRender = vi.hoisted<{
  options: {
    fonts?: unknown;
    setupFutureUsage?: "off_session";
    appearance?: {
      variables?: Record<string, string>;
      rules?: Record<string, Record<string, string>>;
    };
  } | null;
}>(() => ({ options: null }));

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
      options: {
        currency: string;
        amount?: number;
        fonts?: unknown;
        setupFutureUsage?: "off_session";
        appearance?: {
          variables?: Record<string, string>;
          rules?: Record<string, Record<string, string>>;
        };
      };
    }) => {
      elementsRender.options = options;
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
vi.mock("$app/utils/styles", () => ({
  getCssVariable: (name: string) =>
    ({
      "gray-3": "0.5",
      "neutral-accent": "255 144 232",
      "neutral-border-alpha": prefersDark ? "0.35" : "1",
      "neutral-color": prefersDark ? "221 221 221" : "0 0 0",
      "neutral-danger": "220 52 30",
      "neutral-filled": prefersDark ? "0 0 0" : "255 255 255",
    })[name] ?? "9 9 9",
}));
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

const stripeFontsCssSource =
  "https://fonts.googleapis.com/css2?family=Domine:wght@400;600&family=Inter:wght@400;600&family=Merriweather:wght@400;600&family=Roboto%20Mono:wght@400;600&family=Roboto%20Slab:wght@400;600&display=swap";
const sellerTheme: CheckoutTheme = {
  accent_color: "#009a49",
  indicator_color: "#009a49",
  background_color: "#f8efe3",
  text_color: "#000000",
  danger_color: "#9b1c12",
  font_family: '"Roboto Mono", "ABC Favorit", monospace',
};
let prefersDark = false;

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
    prefersDark = false;
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({
        matches: prefersDark,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
      })),
    );
    elementsMounts.currencies = [];
    elementsMounts.amounts = [];
    elementsMounts.unmounts = 0;
    elementsRender.options = null;
    props.onReady.mockClear();
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it("keeps the mounted currency while a surcharge refresh is in flight", () => {
    const { rerender } = render(<PaymentElementInput {...props} amount={1_625} mountCurrency="cad" />);

    expect(elementsMounts.currencies).toEqual(["cad"]);

    rerender(<PaymentElementInput {...props} amount={null} mountCurrency={null} />);
    rerender(<PaymentElementInput {...props} amount={1_750} mountCurrency="cad" />);

    expect(elementsMounts.currencies).toEqual(["cad"]);
    expect(elementsMounts.unmounts).toBe(0);
  });

  it("uses the seller theme instead of CSS sampled before the Inertia head update", () => {
    render(
      <CheckoutThemeProvider value={{ theme: sellerTheme, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    expect(elementsRender.options?.fonts).toEqual([
      { family: "Inter", src: "url(inter.woff2)" },
      { cssSrc: stripeFontsCssSource },
    ]);
    expect(elementsRender.options?.appearance?.variables).toMatchObject({
      colorText: "rgb(0,0,0)",
      colorTextPlaceholder: "rgb(0,0,0, 0.5)",
      colorBackground: "rgb(248,239,227)",
      colorDanger: "rgb(155,28,18)",
      colorPrimary: "rgb(0,0,0)",
      fontFamily: sellerTheme.font_family,
      focusOutline: "2px solid rgb(0,154,73)",
    });
    expect(elementsRender.options?.appearance?.rules?.[".Input"]?.borderColor).toBe("rgb(0,0,0)");
  });

  it("draws the focus ring and selected-method marker from the floored indicator, not the saved accent", () => {
    const theme: CheckoutTheme = {
      ...sellerTheme,
      accent_color: "#ffffff",
      indicator_color: "#949494",
      background_color: "#ffffff",
    };

    render(
      <CheckoutThemeProvider value={{ theme, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    expect(elementsRender.options?.appearance?.variables).toMatchObject({
      colorPrimary: "rgb(0,0,0)",
      focusOutline: "2px solid rgb(148,148,148)",
    });
    expect(elementsRender.options?.appearance?.rules).toMatchObject({
      ".AccordionItem--selected": { borderColor: "rgb(148,148,148)" },
      ".RadioIconOuter--checked": { stroke: "rgb(148,148,148)" },
      ".RadioIconInner--checked": { fill: "rgb(148,148,148)" },
    });
  });

  it("loads seller fonts before a cart-driven theme change without remounting", () => {
    const { rerender } = render(
      <CheckoutThemeProvider value={{ theme: null, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );
    const initialFonts = elementsRender.options?.fonts;

    rerender(
      <CheckoutThemeProvider value={{ theme: sellerTheme, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    expect(elementsMounts.currencies).toEqual(["usd"]);
    expect(elementsMounts.unmounts).toBe(0);
    expect(elementsRender.options?.fonts).toEqual(initialFonts);
    expect(elementsRender.options?.appearance?.variables?.fontFamily).toBe(sellerTheme.font_family);
  });

  it("restores the neutral palette when a cart becomes multi-seller", () => {
    const { rerender } = render(
      <CheckoutThemeProvider value={{ theme: sellerTheme, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    rerender(
      <CheckoutThemeProvider value={{ theme: null, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    expect(elementsMounts.currencies).toEqual(["usd"]);
    expect(elementsMounts.unmounts).toBe(0);
    expect(elementsRender.options?.appearance?.variables).toMatchObject({
      colorText: "rgb(0,0,0)",
      colorTextPlaceholder: "rgb(0,0,0, 0.5)",
      colorBackground: "rgb(255,255,255)",
      colorDanger: "rgb(220,52,30)",
      colorPrimary: "rgb(0,0,0)",
      fontFamily: 'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      focusOutline: "2px solid rgb(255,144,232)",
    });
  });

  it("uses the immutable neutral dark tokens", () => {
    prefersDark = true;

    render(
      <CheckoutThemeProvider value={{ theme: null, stripe_fonts_css_source: stripeFontsCssSource }}>
        <PaymentElementInput {...props} amount={1_625} mountCurrency="usd" />
      </CheckoutThemeProvider>,
    );

    expect(elementsRender.options?.appearance?.variables).toMatchObject({
      colorText: "rgb(221,221,221)",
      colorTextPlaceholder: "rgb(221,221,221, 0.5)",
      colorBackground: "rgb(0,0,0)",
    });
    expect(elementsRender.options?.appearance?.rules?.[".Input"]?.borderColor).toBe("rgb(221,221,221, 0.35)");
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

  it("declares off-session future use for recurring UPI registration", () => {
    const { rerender } = render(<PaymentElementInput {...props} amount={100_000} mountCurrency="inr" />);

    expect(elementsRender.options?.setupFutureUsage).toBeUndefined();

    rerender(<PaymentElementInput {...props} amount={100_000} mountCurrency="inr" setupFutureUsage="off_session" />);

    expect(elementsRender.options?.setupFutureUsage).toBe("off_session");
    expect(elementsMounts.currencies).toEqual(["inr", "inr"]);
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
      act(() => {
        vi.advanceTimersByTime(1_000);
      });
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
