import { Elements, PaymentElement, useElements, useStripe } from "@stripe/react-stripe-js";
import {
  Stripe,
  StripeElements,
  StripeElementsOptions,
  StripePaymentElementChangeEvent,
  StripePaymentElementOptions,
} from "@stripe/stripe-js";
import * as React from "react";

import { getCheckoutStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import {
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT,
  type PaymentElementConfig,
  type PaymentElementClientConfirmConfig,
} from "$app/components/Checkout/payment";
import { useFont } from "$app/components/DesignSettings";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Fieldset } from "$app/components/ui/Fieldset";

export type PaymentElementController = { stripe: Stripe; elements: StripeElements };

// Server-confirm and client-confirm integrations share the Payment Element; only
// server-confirm sets payment_method_creation: "manual".
type CheckoutPaymentElementOptions = PaymentElementConfig | PaymentElementClientConfirmConfig;

type PaymentElementWallets = NonNullable<StripePaymentElementOptions["wallets"]> & { link?: "auto" | "never" };
type LinkPrefillContact = { email: string; name: string };

const paymentElementWallets = (stripeLinkEnabled: boolean): PaymentElementWallets => ({
  applePay: "never",
  googlePay: "never",
  link: stripeLinkEnabled ? "auto" : "never",
});

const CONTACT_PREFILL_DEBOUNCE_MS = 800;

export const PaymentElementInput = ({
  amount,
  mountCurrency,
  elementsOptions,
  disabled,
  defaultEmail,
  defaultName,
  invalid,
  onReady,
  onChange,
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
  disabled?: boolean | undefined;
  defaultEmail: string;
  defaultName: string;
  invalid?: boolean;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
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
    <Fieldset state={invalid ? "danger" : undefined} aria-label="Card information">
      {elementsOptions.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT || mountedAmount !== null ? (
        <StripePaymentElementProvider
          amount={mountedAmount}
          currencyOverride={mountedCurrency}
          elementsOptions={elementsOptions}
        >
          <PaymentElementControllerInput
            amount={mountedAmount}
            disabled={disabled}
            stripeLinkEnabled={elementsOptions.stripe_link_enabled}
            defaultEmail={linkPrefillContact.email}
            defaultName={linkPrefillContact.name}
            onReady={onReady}
            onChange={onChange}
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
  defaultEmail,
  defaultName,
  onReady,
  onChange,
  onTouched,
}: {
  amount: number | null;
  disabled?: boolean | undefined;
  stripeLinkEnabled: boolean;
  defaultEmail: string;
  defaultName: string;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
  onTouched: () => void;
}) => {
  const stripe = useStripe();
  const elements = useElements();
  const [ready, setReady] = React.useState(false);

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
        layout: { type: "tabs" },
        ...(linkDefaultValues ? { defaultValues: linkDefaultValues } : {}),
        fields: {
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
        },
        wallets: paymentElementWallets(stripeLinkEnabled),
      }}
      onReady={() => setReady(true)}
      onFocus={onTouched}
      {...(onChange ? { onChange } : {})}
    />
  );
};

const StripePaymentElementProvider = ({
  amount,
  currencyOverride,
  elementsOptions,
  children,
}: {
  amount: number | null;
  currencyOverride?: string | null | undefined;
  elementsOptions: CheckoutPaymentElementOptions;
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
          ".Tab": {
            display: "none",
          },
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
