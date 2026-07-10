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
  elementsOptions,
  walletsEnabled,
  applePayOption,
  disabled,
  defaultEmail,
  defaultName,
  invalid,
  onReady,
  onChange,
}: {
  amount: number | null;
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
        <StripePaymentElementProvider
          amount={mountedAmount}
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
  walletsEnabled,
  applePayOption,
  defaultEmail,
  defaultName,
  onReady,
  onChange,
  onTouched,
}: {
  amount: number | null;
  disabled?: boolean | undefined;
  stripeLinkEnabled: boolean;
  walletsEnabled: boolean;
  applePayOption?: PaymentElementApplePayOption | undefined;
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
        // With wallets enabled the element must actually show its payment-method surface, so we
        // use the accordion layout (wallet buttons render as express-checkout-style rows). With
        // wallets disabled we keep the tabs layout, whose tabs are hidden via the ".Tab" appearance
        // rule in StripePaymentElementProvider — the exact pre-flag behavior.
        layout: walletsEnabled ? { type: "accordion", radios: false, spacedAccordionItems: true } : { type: "tabs" },
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
      onFocus={onTouched}
      {...(onChange ? { onChange } : {})}
    />
  );
};

const StripePaymentElementProvider = ({
  amount,
  elementsOptions,
  walletsEnabled,
  children,
}: {
  amount: number | null;
  elementsOptions: CheckoutPaymentElementOptions;
  walletsEnabled: boolean;
  children: React.ReactNode;
}) => {
  const [stripePromise] = React.useState(() =>
    getCheckoutStripeInstance(
      "stripe_connect_account_id" in elementsOptions ? elementsOptions.stripe_connect_account_id : null,
    ),
  );
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
    <Elements
      stripe={stripePromise}
      options={options}
      key={`${elementsOptions.stripe_elements_mode}-${elementsOptions.currency}`}
    >
      {children}
    </Elements>
  );
};
