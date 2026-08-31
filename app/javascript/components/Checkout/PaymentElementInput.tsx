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

import {
  getCheckoutThemeColors,
  useCheckoutTheme,
  useCheckoutStripeFonts,
  useNeutralCheckoutThemeColors,
} from "$app/components/Checkout/checkoutTheme";
import {
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
  type PaymentElementConfig,
  type PaymentElementClientConfirmConfig,
} from "$app/components/Checkout/payment";
import { type PaymentElementApplePayOption } from "$app/components/Checkout/paymentElementApplePayOption";
import { useFont } from "$app/components/DesignSettings";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Fieldset } from "$app/components/ui/Fieldset";

export type PaymentElementController = { stripe: Stripe; elements: StripeElements; mountCurrency: string };

// Server-confirm and client-confirm integrations share the Payment Element; only
// server-confirm sets payment_method_creation: "manual".
type CheckoutPaymentElementOptions = PaymentElementConfig | PaymentElementClientConfirmConfig;

type PaymentElementWallets = NonNullable<StripePaymentElementOptions["wallets"]> & { link?: "auto" | "never" };

const CLIENT_CONFIRM_USD_ONLY_PAYMENT_METHODS = new Set(["us_bank_account", "cashapp", "klarna", "alipay"]);
const CLIENT_CONFIRM_FORCED_PAYMENT_METHOD_CURRENCIES: Record<string, string> = {
  ideal: "eur",
  bancontact: "eur",
  upi: "inr",
  pix: "brl",
};

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
  setupFutureUsage,
  walletsEnabled,
  flatLayout,
  applePayOption,
  disabled,
  defaultEmail,
  defaultName,
  defaultCountry,
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
  // Stripe requires the confirmation token to carry the same future-use contract as the deferred PaymentIntent.
  setupFutureUsage?: "off_session" | undefined;
  // Per-seller rollout flag (payment_element_wallets): show Apple Pay/Google Pay inside the
  // Payment Element instead of via the separate Payment Request Button.
  walletsEnabled: boolean;
  // Render the element with the accordion layout so it acts as checkout's payment-method
  // selector (the flat payment-methods list — see PaymentMethodsSection in PaymentForm.tsx).
  // Independent of walletsEnabled since the layout was decoupled from the wallet rollout:
  // a wallet-suppressed cart (disable_wallets) still renders the flat accordion, just without
  // wallet rows. When false the element is purely an internal card form (tabs layout, tabs
  // hidden) — the pre-flat-list behavior.
  flatLayout: boolean;
  // Apple Pay recurring declaration (merchant-token rollout): describes the cart's recurring
  // agreement on the Apple Pay sheet so Apple issues a device-independent merchant token. The
  // caller derives it from cart state (see paymentElementApplePayOption.ts) and memoizes it on
  // its content so option updates only reach the mounted element when the declaration actually
  // changes. Undefined leaves the element's options untouched (flags off / client-confirm lane).
  applePayOption?: PaymentElementApplePayOption | undefined;
  disabled?: boolean | undefined;
  defaultEmail: string;
  defaultName: string;
  // Prefill for the country the Payment Element's own address form starts on when a selection
  // has the element collect the full billing details ("element-full" — UPI on digital carts).
  // Checkout's GeoIP-detected country is the best guess, and prefilling it means the buyer's
  // pane opens on the right country's address format instead of Stripe's default.
  defaultCountry: string;
  // Whether the cart requires shipping, i.e. whether checkout's own form is collecting a full
  // street address. Drives which billing-details fields the element renders for methods that
  // need an address (see paymentElementBillingDetailsCollection).
  hasShippingCart: boolean;
  invalid?: boolean;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
  // Fires when the buyer focuses any field inside the element. Used by the flat payment-methods layout
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

  // The prefill values handed to the element as defaultValues, debounced so the mounted
  // element isn't updated on every keystroke of checkout's email/name fields. Two freezing
  // policies:
  // - Link's email prefill FREEZES once the buyer touches the element: Link reacts to its
  //   email default by re-running lookup UI, which would disrupt an in-progress interaction.
  // - The name prefill keeps FOLLOWING checkout's Full name field even after a touch: it only
  //   materializes when a pane that collects a name renders its fields (the UPI element-full
  //   pane) — nothing on the card/Link surface reacts to it, and freezing it caused the
  //   reviewed bug where a buyer who touched the element before typing their name got an
  //   empty Name field in the UPI pane (PR #6191 review).
  const [linkPrefillEmail, setLinkPrefillEmail] = React.useState(defaultEmail);
  const [prefillName, setPrefillName] = React.useState(defaultName);
  const paymentElementTouchedRef = React.useRef(false);
  const handlePaymentElementTouched = React.useCallback(() => {
    paymentElementTouchedRef.current = true;
  }, []);
  React.useEffect(() => {
    const handle = setTimeout(() => {
      if (elementsOptions.stripe_link_enabled && !paymentElementTouchedRef.current) {
        setLinkPrefillEmail(defaultEmail);
      }
      setPrefillName(defaultName);
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
      // the container) applies. Scoped to flatLayout to leave the legacy card form
      // byte-identical to production.
      className={flatLayout ? "[&_iframe]:max-w-none" : undefined}
    >
      {elementsOptions.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT || mountedAmount !== null ? (
        <StripePaymentElementProvider
          amount={mountedAmount}
          currencyOverride={mountedCurrency}
          elementsOptions={elementsOptions}
          setupFutureUsage={setupFutureUsage}
          flatLayout={flatLayout}
        >
          <PaymentElementControllerInput
            amount={mountedAmount}
            mountCurrency={mountedCurrency ?? elementsOptions.currency}
            disabled={disabled}
            stripeLinkEnabled={elementsOptions.stripe_link_enabled}
            walletsEnabled={walletsEnabled}
            flatLayout={flatLayout}
            applePayOption={applePayOption}
            linkPrefillEmail={linkPrefillEmail}
            defaultName={prefillName}
            defaultCountry={defaultCountry}
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
  mountCurrency,
  disabled,
  stripeLinkEnabled,
  walletsEnabled,
  flatLayout,
  applePayOption,
  linkPrefillEmail,
  defaultName,
  defaultCountry,
  hasShippingCart,
  onReady,
  onChange,
  onFocus,
  onTouched,
}: {
  amount: number | null;
  mountCurrency: string;
  disabled?: boolean | undefined;
  stripeLinkEnabled: boolean;
  walletsEnabled: boolean;
  flatLayout: boolean;
  applePayOption?: PaymentElementApplePayOption | undefined;
  // The debounce-frozen email snapshot for Link's prefill (see PaymentElementInput):
  // deliberately stops following checkout's email field once the buyer touches the element,
  // so Link's own lookup UI isn't disrupted mid-interaction.
  linkPrefillEmail: string;
  // The (debounced) LIVE name from checkout's Full name field (state.fullName) — unlike the
  // Link email snapshot this keeps following the form after a touch. It feeds the element's
  // defaultValues, which only materialize when a pane that collects a name renders (the UPI
  // element-full pane) — see the defaultValues memo below.
  defaultName: string;
  defaultCountry: string;
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
    onReady(stripe && elements && ready ? { stripe, elements, mountCurrency } : null);
    return () => onReady(null);
  }, [stripe, elements, ready, mountCurrency, onReady]);

  React.useEffect(() => {
    if (amount !== null) elements?.update({ amount });
  }, [amount, elements]);

  // The element's defaultValues: Link's email prefill plus the name/country checkout already
  // knows. Stripe treats defaultValues as INITIAL values, applied only when a field first
  // renders — pushing them via element.update() after a field is on screen (or in the same
  // tick it renders) does nothing (verified in the browser-level UPI regression spec). That
  // limitation is why the pane's name field is pinned to "never" on every mode (see fields
  // below) and checkout keeps its own Full name field: a name typed before switching to UPI
  // could never be carried into a later-rendered pane field. The values here matter where
  // fields DO render with them from the start — Link's email lookup, and the pane's country
  // for the element-full address form, which is GeoIP-known at mount.
  const defaultValues = React.useMemo<StripePaymentElementOptions["defaultValues"] | undefined>(() => {
    const billingDetails = {
      ...(stripeLinkEnabled && linkPrefillEmail ? { email: linkPrefillEmail } : {}),
      ...(defaultName ? { name: defaultName } : {}),
      ...(defaultCountry ? { address: { country: defaultCountry } } : {}),
    };
    return Object.keys(billingDetails).length > 0 ? { billingDetails } : undefined;
  }, [stripeLinkEnabled, linkPrefillEmail, defaultCountry, defaultName]);

  return (
    <PaymentElement
      options={{
        readOnly: disabled ?? false,
        // On the flat payment-methods list the element must actually show its payment-method
        // surface, so we use the accordion layout (each method — card, wallets when enabled,
        // local methods — renders as a row). Off the flat list the element is purely an internal
        // card form: it keeps the tabs layout, whose tabs are hidden via the ".Tab" appearance
        // rule in StripePaymentElementProvider — the exact pre-flat-list behavior.
        layout: flatLayout ? { type: "accordion", radios: false, spacedAccordionItems: true } : { type: "tabs" },
        ...(defaultValues ? { defaultValues } : {}),
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
        // - "element-full" (UPI on digital carts): Stripe requires billing_details.name and a
        //   full street address to CONFIRM a UPI payment, and checkout's digital form has no
        //   street-address fields. With everything pinned to "never" the confirm always failed
        //   server-side with parameter_missing and no last_payment_error — buyers could never
        //   complete a UPI purchase (the July 2026 UPI ramp-down, gumroad-private#933). On this
        //   mode Stripe's pane collects the full street address itself — with its own localized
        //   labels and validation — while checkout's Country/ZIP fields hide for the selection
        //   (see SharedInputs in PaymentForm.tsx) so nothing is asked for twice. Name and email
        //   stay "never": both remain checkout's own fields (the Full name field stays visible
        //   for UPI) and tokenization passes them alongside, exactly like "form" mode. Name
        //   deliberately does NOT move into the pane: the pane's fields only apply defaultValues
        //   present when they first render, so a name typed into checkout before switching to
        //   UPI could not be carried over — the buyer would retype a name checkout already knew
        //   (PR #6191 review).
        // The switch reaches the mounted element through react-stripe-js's option diffing
        // (element.update) as soon as the change event reports the row selection — before
        // tokenization, which only starts from the pay click.
        fields: {
          billingDetails:
            billingDetailsCollection === "element"
              ? "auto"
              : billingDetailsCollection === "element-full"
                ? { name: "never", email: "never", phone: "never", address: "auto" }
                : {
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
  setupFutureUsage,
  flatLayout,
  children,
}: {
  amount: number | null;
  currencyOverride?: string | null | undefined;
  elementsOptions: CheckoutPaymentElementOptions;
  setupFutureUsage?: "off_session" | undefined;
  flatLayout: boolean;
  children: React.ReactNode;
}) => {
  const [stripePromise] = React.useState(() =>
    getCheckoutStripeInstance(
      "stripe_connect_account_id" in elementsOptions ? elementsOptions.stripe_connect_account_id : null,
    ),
  );
  const currency = currencyOverride ?? elementsOptions.currency;
  // Prepare applies the same narrowing before creating the deferred intent. This matters when a
  // quote or surcharge edit remounts an Element whose server-issued list came from another currency.
  const paymentMethodTypes = React.useMemo(
    () =>
      elementsOptions.payment_method_types.filter((paymentMethodType) => {
        if (currency !== "usd" && CLIENT_CONFIRM_USD_ONLY_PAYMENT_METHODS.has(paymentMethodType)) return false;
        const forcedCurrency = CLIENT_CONFIRM_FORCED_PAYMENT_METHOD_CURRENCIES[paymentMethodType];
        return forcedCurrency === undefined || forcedCurrency === currency;
      }),
    [currency, elementsOptions.payment_method_types],
  );
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
  const checkoutTheme = useCheckoutTheme();
  const neutralColors = useNeutralCheckoutThemeColors();
  const colors = React.useMemo(
    () => (checkoutTheme ? getCheckoutThemeColors(checkoutTheme) : neutralColors),
    [checkoutTheme, neutralColors],
  );
  const fontFamily =
    checkoutTheme?.font_family ?? `${font.name}, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;
  const stripeFonts = useCheckoutStripeFonts(font);

  const options = React.useMemo<StripeElementsOptions>(
    () => ({
      mode: elementsOptions.stripe_elements_mode,
      currency,
      ...(initialAmount === null ? {} : { amount: initialAmount }),
      ...(setupFutureUsage ? { setupFutureUsage } : {}),
      paymentMethodTypes,
      // Stripe rejects createConfirmationToken({ elements }) when payment_method_creation is manual.
      ...("payment_method_creation" in elementsOptions
        ? { paymentMethodCreation: elementsOptions.payment_method_creation }
        : {}),
      fonts: stripeFonts,
      appearance: {
        variables: {
          fontFamily,
          fontSizeBase: "1rem",
          fontSizeSm: "0.875rem",
          fontLineHeight: "1.375",
          spacingUnit: "0.25rem",
          gridRowSpacing: "1rem",
          gridColumnSpacing: "1rem",
          colorText: colors.text,
          colorTextPlaceholder: colors.placeholder,
          colorBackground: colors.background,
          colorDanger: colors.danger,
          colorPrimary: colors.text,
          borderRadius: "4px",
          focusOutline: `2px solid ${colors.indicator}`,
          focusBoxShadow: "none",
        },
        rules: {
          // Off the flat payment-methods list the element uses the tabs layout purely as an
          // internal card form, so the tabs themselves are hidden. On the flat list the element
          // switches to the accordion layout and must show its payment-method rows, so the tabs
          // rule is dropped and the accordion items are styled to match our inputs.
          ...(flatLayout
            ? {
                ".AccordionItem": {
                  borderColor: colors.border,
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
            borderColor: colors.border,
            boxShadow: "none",
            minHeight: "3rem",
            padding: "0.75rem 1rem",
          },
          ".Input:focus": {
            boxShadow: "none",
          },
          ".AccordionItem--selected": {
            borderColor: colors.indicator,
          },
          ".RadioIconOuter--checked": {
            stroke: colors.indicator,
          },
          ".RadioIconInner--checked": {
            fill: colors.indicator,
          },
          ".Label": {
            color: colors.text,
            fontSize: "1rem",
            fontWeight: "400",
            marginBottom: "0.5rem",
          },
        },
      },
    }),
    [
      colors,
      currency,
      elementsOptions,
      flatLayout,
      fontFamily,
      initialAmount,
      paymentMethodTypes,
      setupFutureUsage,
      stripeFonts,
    ],
  );

  return (
    // The key includes the effective mount currency so a currency change (e.g. the buyer-currency
    // FX quote arriving after the initial USD mount, or disappearing when the buyer opts to save
    // their card) remounts Elements — Stripe supports amount updates on a live element but not
    // currency changes. Future-use setup is also creation-time configuration.
    <Elements
      stripe={stripePromise}
      options={options}
      key={`${elementsOptions.stripe_elements_mode}-${currency}-${setupFutureUsage ?? "none"}`}
    >
      {children}
    </Elements>
  );
};
