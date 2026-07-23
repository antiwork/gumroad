import { Elements, PaymentElement, useElements, useStripe } from "@stripe/react-stripe-js";
import {
  Stripe,
  StripeElements,
  StripeElementsOptions,
  StripePaymentElementChangeEvent,
  StripePaymentElementOptions,
} from "@stripe/stripe-js";
import * as React from "react";

import { paymentElementBillingDetailsCollection } from "$app/data/card_payment_method_data";
import { getCheckoutStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import {
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
  type PaymentElementConfig,
  type PaymentElementClientConfirmConfig,
} from "$app/components/Checkout/payment";
import { type PaymentElementApplePayOption } from "$app/components/Checkout/paymentElementApplePayOption";
import { useFont } from "$app/components/DesignSettings";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Fieldset } from "$app/components/ui/Fieldset";

export type PaymentElementController = { stripe: Stripe; elements: StripeElements };

// Server-confirm and client-confirm integrations share the Payment Element; only
// server-confirm sets payment_method_creation: "manual".
type CheckoutPaymentElementOptions = PaymentElementConfig | PaymentElementClientConfirmConfig;

type PaymentElementWallets = NonNullable<StripePaymentElementOptions["wallets"]> & { link?: "auto" | "never" };
type LinkPrefillContact = { email: string; name: string };

// When the payment_element_wallets rollout flag is off, Apple Pay and Google Pay are pinned to
// "never" — that was the Phase-1 duplication guard while the separate Payment Request Button
// rendered next to the element, and it stays in place for sellers not yet on the flag. When the
// flag is on, the Payment Request Button is not mounted for the cart (that suppression lives in
// PaymentForm.tsx), so the element itself can show the wallet buttons without duplicates.
// See antiwork/gumroad#5768 (and #5362 for the original duplication guard).
const paymentElementWallets = (stripeLinkEnabled: boolean, walletsEnabled: boolean): PaymentElementWallets => ({
  applePay: walletsEnabled ? "auto" : "never",
  googlePay: walletsEnabled ? "auto" : "never",
  link: stripeLinkEnabled ? "auto" : "never",
});

const CONTACT_PREFILL_DEBOUNCE_MS = 800;

export const PaymentElementInput = ({
  amount,
  mountCurrency,
  elementsOptions,
  walletsEnabled,
  applePayOption,
  disabled,
  defaultEmail,
  defaultName,
  hasShippingCart,
  invalid,
  onReady,
  onChange,
  onFocus,
}: {
  amount: number | null;
  // Mounts the element in this currency instead of elementsOptions.currency (from
  // getStripePaymentElementMountCurrency). Used by the buyer-currency presentment lane, where
  // the currency comes from the checkout's FX quote (browser state) rather than from the
  // server-rendered config. When set, `amount` must be minor units of this currency. Like
  // `amount`, null means "not knowable right now" and keeps the last mounted currency (see
  // mountedCurrency below) — a currency change remounts the element (it's part of the provider
  // key, because Stripe does not allow currency updates on a live element), which wipes any
  // card details the buyer already entered, so it must only happen on real transitions, never
  // while a surcharge refresh is merely in flight.
  mountCurrency?: string | null | undefined;
  elementsOptions: CheckoutPaymentElementOptions;
  // Per-seller rollout flag (payment_element_wallets): show Apple Pay/Google Pay inside the
  // Payment Element instead of via the separate Payment Request Button.
  walletsEnabled: boolean;
  // Apple Pay recurring declaration (merchant-token rollout): describes the cart's recurring
  // agreement on the Apple Pay sheet so Apple issues a device-independent merchant token. The
  // caller derives it from cart state (see paymentElementApplePayOption.ts) and memoizes it on
  // its content so option updates only reach the mounted element when the declaration actually
  // changes. Undefined leaves the element's options untouched (flags off / client-confirm lane).
  applePayOption?: PaymentElementApplePayOption | undefined;
  disabled?: boolean | undefined;
  defaultEmail: string;
  defaultName: string;
  // Whether the cart requires shipping, i.e. whether checkout's own form is collecting a full
  // street address. Drives which billing-details fields the element renders for methods that
  // need an address (see paymentElementBillingDetailsCollection).
  hasShippingCart: boolean;
  invalid?: boolean;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
  // Fires when the buyer focuses any field inside the element. Used by the flat wallets layout
  // (see PaymentMethodsSection in PaymentForm.tsx) to re-select the card/wallet lane when the
  // buyer returns to the element after picking PayPal — clicks inside the element's iframe never
  // reach the surrounding DOM, so this Stripe event is the only reliable interaction signal.
  onFocus?: (() => void) | undefined;
}) => {
  const [mountedAmount, setMountedAmount] = React.useState(amount);

  React.useEffect(() => {
    if (amount !== null) setMountedAmount(amount);
  }, [amount]);

  const [mountedCurrency, setMountedCurrency] = React.useState(mountCurrency ?? null);

  React.useEffect(() => {
    if (mountCurrency != null) setMountedCurrency(mountCurrency);
  }, [mountCurrency]);

  const [linkPrefillContact, setLinkPrefillContact] = React.useState<LinkPrefillContact>(() => ({
    email: defaultEmail,
    name: defaultName,
  }));
  const paymentElementTouchedRef = React.useRef(false);
  const handlePaymentElementTouched = React.useCallback(() => {
    paymentElementTouchedRef.current = true;
  }, []);
  React.useEffect(() => {
    if (!elementsOptions.stripe_link_enabled) return;
    if (paymentElementTouchedRef.current) return;
    const handle = setTimeout(() => {
      if (paymentElementTouchedRef.current) return;
      setLinkPrefillContact({ email: defaultEmail, name: defaultName });
    }, CONTACT_PREFILL_DEBOUNCE_MS);
    return () => clearTimeout(handle);
  }, [defaultEmail, defaultName, elementsOptions.stripe_link_enabled]);

  return (
    <Fieldset
      state={invalid ? "danger" : undefined}
      aria-label="Card information"
      // Stripe sizes the element's iframe as `width: calc(100% + 8px); margin: 0 -4px` — a 4px
      // bleed on each side that its inner UI offsets back, so focus rings can render outside the
      // rows without clipping. Our global base rule (`* { max-width: 100% }` in _global.scss)
      // clamps the iframe back to the container width while the -4px left margin still applies,
      // shifting the element's content 4px left and leaving it 8px narrower than the container —
      // which made the accordion rows visibly narrower than the flat PayPal row below. Lift the
      // clamp for the element's iframes so Stripe's intended geometry (content edges flush with
      // the container) applies. Scoped to walletsEnabled to leave the flag-off card form
      // byte-identical to production.
      className={walletsEnabled ? "[&_iframe]:max-w-none" : undefined}
    >
      {elementsOptions.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT || mountedAmount !== null ? (
        <StripePaymentElementProvider
          amount={mountedAmount}
          currencyOverride={mountedCurrency}
          elementsOptions={elementsOptions}
          walletsEnabled={walletsEnabled}
        >
          <PaymentElementControllerInput
            amount={mountedAmount}
            disabled={disabled}
            stripeLinkEnabled={elementsOptions.stripe_link_enabled}
            walletsEnabled={walletsEnabled}
            applePayOption={applePayOption}
            defaultEmail={linkPrefillContact.email}
            defaultName={linkPrefillContact.name}
            hasShippingCart={hasShippingCart}
            onReady={onReady}
            onChange={onChange}
            onFocus={onFocus}
            onTouched={handlePaymentElementTouched}
          />
        </StripePaymentElementProvider>
      ) : (
        <div className="bg-input flex min-h-16 items-center justify-center rounded border border-border p-4">
          <LoadingSpinner />
        </div>
      )}
    </Fieldset>
  );
};

const PaymentElementControllerInput = ({
  amount,
  disabled,
  stripeLinkEnabled,
  walletsEnabled,
  applePayOption,
  defaultEmail,
  defaultName,
  hasShippingCart,
  onReady,
  onChange,
  onFocus,
  onTouched,
}: {
  amount: number | null;
  disabled?: boolean | undefined;
  stripeLinkEnabled: boolean;
  walletsEnabled: boolean;
  applePayOption?: PaymentElementApplePayOption | undefined;
  defaultEmail: string;
  defaultName: string;
  hasShippingCart: boolean;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
  onFocus?: (() => void) | undefined;
  onTouched: () => void;
}) => {
  const stripe = useStripe();
  const elements = useElements();
  const [ready, setReady] = React.useState(false);
  // Which payment-method row the buyer currently has selected inside the element ("card",
  // "apple_pay", "google_pay", ...), reported by the element's change event. State (not a ref)
  // because it drives the fields option below, which must reach the mounted element via
  // element.update() when the selection flips between card and wallet.
  const [selectedType, setSelectedType] = React.useState("card");
  const billingDetailsCollection = paymentElementBillingDetailsCollection(selectedType, hasShippingCart);

  React.useEffect(() => {
    onReady(stripe && elements && ready ? { stripe, elements } : null);
    return () => onReady(null);
  }, [stripe, elements, ready, onReady]);

  React.useEffect(() => {
    if (amount !== null) elements?.update({ amount });
  }, [amount, elements]);

  const linkDefaultValues = React.useMemo<StripePaymentElementOptions["defaultValues"] | undefined>(() => {
    if (!stripeLinkEnabled) return undefined;

    const billingDetails = {
      ...(defaultEmail ? { email: defaultEmail } : {}),
      ...(defaultName ? { name: defaultName } : {}),
    };
    return Object.keys(billingDetails).length > 0 ? { billingDetails } : undefined;
  }, [defaultEmail, defaultName, stripeLinkEnabled]);

  return (
    <PaymentElement
      options={{
        readOnly: disabled ?? false,
        // With wallets enabled the element must actually show its payment-method surface, so we
        // use the accordion layout (wallet buttons render as express-checkout-style rows). With
        // wallets disabled we keep the tabs layout, whose tabs are hidden via the ".Tab" appearance
        // rule in StripePaymentElementProvider — the exact pre-flag behavior.
        layout: walletsEnabled ? { type: "accordion", radios: false, spacedAccordionItems: true } : { type: "tabs" },
        ...(linkDefaultValues ? { defaultValues: linkDefaultValues } : {}),
        // Checkout collects billing details in its own form, so each element field is only shown
        // when checkout does NOT already ask for it — nothing should be asked for twice. The
        // collection mode (see paymentElementBillingDetailsCollection) decides per selection:
        // - "form" (cards, Link, iDEAL): every field pinned to "never"; tokenization passes the
        //   form's values explicitly (see paymentElementBillingDetails in
        //   card_payment_method_data.ts). Stripe's client-side validation rejects
        //   createPaymentMethod/createConfirmationToken with an IntegrationError ("You specified
        //   "never" for fields.billing_details.name … but did not pass
        //   params.billing_details.name") whenever a field is "never" and no param is passed,
        //   which is why the override is mandatory on this mode.
        // - "element" (wallets): the whole block is "auto" — the wallet sheet supplies the
        //   buyer's verified billing details and tokenization deliberately passes no override.
        //   Nothing extra renders on the page (the sheet is its own surface).
        // - "element-address" (UPI on digital carts): Stripe requires billing_details.name and a
        //   full street address to CONFIRM a UPI payment, and checkout's digital form has no
        //   street-address fields. With everything pinned to "never" the confirm always failed
        //   server-side with parameter_missing and no last_payment_error — buyers could never
        //   complete a UPI purchase (the July 2026 UPI ramp-down, gumroad-private#933). Only the
        //   street-address fields render inside the UPI pane (the one thing the form doesn't
        //   have); name/email/country stay "never" because checkout's form already collects
        //   those, and tokenization passes them alongside. On shippable carts the form collects
        //   the full address itself, so UPI stays on "form" and no element fields appear.
        // The switch reaches the mounted element through react-stripe-js's option diffing
        // (element.update) as soon as the change event reports the row selection — before
        // tokenization, which only starts from the pay click.
        fields: {
          billingDetails:
            billingDetailsCollection === "element"
              ? "auto"
              : {
                  name: "never",
                  email: "never",
                  phone: "never",
                  address:
                    billingDetailsCollection === "element-address"
                      ? {
                          country: "never",
                          postalCode: "auto",
                          state: "auto",
                          city: "auto",
                          line1: "auto",
                          line2: "auto",
                        }
                      : {
                          country: "never",
                          postalCode: "never",
                          state: "never",
                          city: "never",
                          line1: "never",
                          line2: "never",
                        },
                },
        },
        wallets: paymentElementWallets(stripeLinkEnabled, walletsEnabled),
        // The recurring declaration attaches to the PaymentElement's own options (that's where
        // Stripe's typings put `applePay`), not to the Elements provider. react-stripe-js diffs
        // these options on every render and pushes real changes to the mounted element via
        // element.update(), so cart edits that change the declaration update the sheet without a
        // remount — and the provider's mode+currency key already remounts everything when the
        // element switches between payment and setup mode.
        ...(applePayOption ? { applePay: applePayOption } : {}),
      }}
      onReady={() => setReady(true)}
      onFocus={() => {
        onTouched();
        onFocus?.();
      }}
      onChange={(event) => {
        setSelectedType(event.value.type);
        onChange?.(event);
      }}
    />
  );
};

const StripePaymentElementProvider = ({
  amount,
  currencyOverride,
  elementsOptions,
  walletsEnabled,
  children,
}: {
  amount: number | null;
  currencyOverride?: string | null | undefined;
  elementsOptions: CheckoutPaymentElementOptions;
  walletsEnabled: boolean;
  children: React.ReactNode;
}) => {
  const [stripePromise] = React.useState(() =>
    getCheckoutStripeInstance(
      "stripe_connect_account_id" in elementsOptions ? elementsOptions.stripe_connect_account_id : null,
    ),
  );
  const currency = currencyOverride ?? elementsOptions.currency;
  // The amount and currency Elements is CREATED with, captured together. Later amount
  // changes reach the live element through elements.update() in
  // PaymentElementControllerInput, so this deliberately does not follow every amount
  // change. But a currency change remounts Elements (the currency is part of its key
  // below), and the new instance must not be created with an amount captured under the
  // previous currency — that value is denominated in the previous currency's minor
  // units (e.g. a CAD total reused for a USD mount). Re-capture the amount at the
  // moment the currency changes so creation options are always internally consistent.
  const [creation, setCreation] = React.useState({ currency, amount });
  if (creation.currency !== currency) setCreation({ currency, amount });
  const initialAmount = creation.amount;
  const font = useFont();
  const color = getCssVariable("color").split(" ").join(",");
  const backgroundColor = `rgb(${getCssVariable("filled").split(" ").join(",")})`;
  const borderColor = `rgb(${color}, ${getCssVariable("border-alpha")})`;
  const dangerColor = `rgb(${getCssVariable("danger").split(" ").join(",")})`;
  const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
  const fontFamily = `${font.name}, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;

  const options = React.useMemo<StripeElementsOptions>(
    () => ({
      mode: elementsOptions.stripe_elements_mode,
      currency,
      ...(initialAmount === null ? {} : { amount: initialAmount }),
      paymentMethodTypes: elementsOptions.payment_method_types,
      // Stripe rejects createConfirmationToken({ elements }) when payment_method_creation is manual.
      ...("payment_method_creation" in elementsOptions
        ? { paymentMethodCreation: elementsOptions.payment_method_creation }
        : {}),
      fonts: [{ family: font.name, src: `url(${font.url})` }],
      appearance: {
        variables: {
          fontFamily,
          fontSizeBase: "1rem",
          fontSizeSm: "0.875rem",
          fontLineHeight: "1.375",
          spacingUnit: "0.25rem",
          gridRowSpacing: "1rem",
          gridColumnSpacing: "1rem",
          colorText: `rgb(${color})`,
          colorTextPlaceholder: placeholderColor,
          colorBackground: backgroundColor,
          colorDanger: dangerColor,
          borderRadius: "4px",
          focusOutline: `2px solid rgb(${getCssVariable("accent").split(" ").join(",")})`,
          focusBoxShadow: "none",
        },
        rules: {
          // With wallets disabled the element uses the tabs layout purely as an internal card
          // form, so the tabs themselves are hidden. With wallets enabled the element switches to
          // the accordion layout and must show its payment-method rows, so the tabs rule is
          // dropped and the accordion items are styled to match our inputs.
          ...(walletsEnabled
            ? {
                ".AccordionItem": {
                  borderColor,
                  boxShadow: "none",
                  borderRadius: "4px",
                  // Match the flat PayPal row appended below the element (p-4 in
                  // FlatPayPalRow), so every payment-method row has the same height.
                  padding: "1rem",
                },
              }
            : {
                ".Tab": {
                  display: "none",
                },
              }),
          ".TabLabel": {
            fontSize: "1rem",
            fontWeight: "400",
          },
          ".Input": {
            borderColor,
            boxShadow: "none",
            minHeight: "3rem",
            padding: "0.75rem 1rem",
          },
          ".Input:focus": {
            boxShadow: "none",
          },
          ".Label": {
            color: `rgb(${color})`,
            fontSize: "1rem",
            fontWeight: "400",
            marginBottom: "0.5rem",
          },
        },
      },
    }),
    [
      backgroundColor,
      borderColor,
      color,
      currency,
      dangerColor,
      elementsOptions,
      font.name,
      font.url,
      fontFamily,
      initialAmount,
      placeholderColor,
      walletsEnabled,
    ],
  );

  return (
    // The key includes the effective mount currency so a currency change (e.g. the buyer-currency
    // FX quote arriving after the initial USD mount, or disappearing when the buyer opts to save
    // their card) remounts Elements — Stripe supports amount updates on a live element but not
    // currency changes.
    <Elements stripe={stripePromise} options={options} key={`${elementsOptions.stripe_elements_mode}-${currency}`}>
      {children}
    </Elements>
  );
};
