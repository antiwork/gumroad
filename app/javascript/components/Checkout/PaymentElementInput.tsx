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

import { STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT, type PaymentElementConfig } from "$app/components/Checkout/payment";
import { useFont } from "$app/components/DesignSettings";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Fieldset } from "$app/components/ui/Fieldset";

export type PaymentElementController = { stripe: Stripe; elements: StripeElements };

type PaymentElementWallets = NonNullable<StripePaymentElementOptions["wallets"]> & { link?: "auto" | "never" };

const PAYMENT_ELEMENT_WALLETS: PaymentElementWallets = {
  applePay: "never",
  googlePay: "never",
  link: "never",
};

export const PaymentElementInput = ({
  amount,
  elementsOptions,
  disabled,
  invalid,
  onReady,
  onChange,
}: {
  amount: number | null;
  elementsOptions: PaymentElementConfig;
  disabled?: boolean | undefined;
  invalid?: boolean;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
}) => {
  const [mountedAmount, setMountedAmount] = React.useState(amount);

  React.useEffect(() => {
    if (amount !== null) setMountedAmount(amount);
  }, [amount]);

  return (
    <Fieldset state={invalid ? "danger" : undefined} aria-label="Card information">
      {elementsOptions.stripe_elements_mode === STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT || mountedAmount !== null ? (
        <StripePaymentElementProvider amount={mountedAmount} elementsOptions={elementsOptions}>
          <PaymentElementControllerInput
            amount={mountedAmount}
            disabled={disabled}
            onReady={onReady}
            onChange={onChange}
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
  onReady,
  onChange,
}: {
  amount: number | null;
  disabled?: boolean | undefined;
  onReady: (controller: PaymentElementController | null) => void;
  onChange?: ((event: StripePaymentElementChangeEvent) => void) | undefined;
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

  return (
    <PaymentElement
      options={{
        readOnly: disabled ?? false,
        layout: { type: "tabs" },
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
        wallets: PAYMENT_ELEMENT_WALLETS,
      }}
      onReady={() => setReady(true)}
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
  elementsOptions: PaymentElementConfig;
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
      paymentMethodCreation: elementsOptions.payment_method_creation,
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
