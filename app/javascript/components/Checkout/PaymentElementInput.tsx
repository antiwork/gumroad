import { Elements, PaymentElement, useElements, useStripe } from "@stripe/react-stripe-js";
import {
  Stripe,
  StripeElements,
  StripeElementsOptions,
  StripePaymentElementChangeEvent,
  StripePaymentElementOptions,
} from "@stripe/stripe-js";
import * as React from "react";

import { getStripeInstance } from "$app/utils/stripe_loader";
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
  elementsOptions,
  disabled,
  defaultEmail,
  defaultName,
  invalid,
  onReady,
  onChange,
}: {
  amount: number | null;
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
        <StripePaymentElementProvider amount={mountedAmount} elementsOptions={elementsOptions}>
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
  elementsOptions,
  children,
}: {
  amount: number | null;
  elementsOptions: CheckoutPaymentElementOptions;
  children: React.ReactNode;
}) => {
  const [stripePromise] = React.useState(getStripeInstance);
  const [initialAmount] = React.useState(amount);
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
      currency: elementsOptions.currency,
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
    <Elements
      stripe={stripePromise}
      options={options}
      key={`${elementsOptions.stripe_elements_mode}-${elementsOptions.currency}`}
    >
      {children}
    </Elements>
  );
};
