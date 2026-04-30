import { CreditCard } from "@boxicons/react";
import { Elements, PaymentElement, useElements } from "@stripe/react-stripe-js";
import { Appearance, StripeElements, StripeElementsOptionsMode } from "@stripe/stripe-js";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import { getStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import { useFont } from "$app/components/DesignSettings";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

const MIN_STRIPE_AMOUNT_CENTS = 50;

const ElementsBridge = ({ onReady }: { onReady: (elements: StripeElements) => void }) => {
  const elements = useElements();
  const calledRef = React.useRef(false);

  React.useEffect(() => {
    if (elements && !calledRef.current) {
      calledRef.current = true;
      onReady(elements);
    }
  }, [elements]);

  return null;
};

export const CreditCardInput = ({
  disabled,
  savedCreditCard,
  onReady,
  useSavedCard,
  setUseSavedCard,
  amount,
  paymentMethodTypes = ["card", "link"],
}: {
  disabled?: boolean;
  savedCreditCard: SavedCreditCard | null;
  onReady: (elements: StripeElements) => void;
  useSavedCard: boolean;
  setUseSavedCard: (value: boolean) => void;
  amount: number;
  paymentMethodTypes?: string[];
}) => {
  const [appearance, setAppearance] = React.useState<Appearance | null>(null);

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label>Payment details</Label>
        {savedCreditCard ? (
          <button
            className="cursor-pointer font-normal underline all-unset"
            disabled={disabled}
            onClick={() => setUseSavedCard(!useSavedCard)}
          >
            {useSavedCard ? "Use a different card?" : "Use saved card"}
          </button>
        ) : null}
      </FieldsetTitle>
      {savedCreditCard && useSavedCard ? (
        <InputGroup readOnly aria-label="Saved credit card">
          <CreditCard className="size-5" />
          <span>{savedCreditCard.number}</span>
          <span style={{ marginLeft: "auto" }}>{savedCreditCard.expiration_date}</span>
        </InputGroup>
      ) : (
        <>
          {appearance == null ? (
            <input
              className="invisible absolute"
              ref={(el) => {
                if (el == null) return;
                const inputStyle = window.getComputedStyle(el);
                const color = getCssVariable("color").split(" ").join(",");
                const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                const sanitizedFontFamily = inputStyle.fontFamily.replace(/\\[0-9a-fA-F]+\s?/gu, "");
                setAppearance({
                  variables: {
                    fontFamily: sanitizedFontFamily || "sans-serif",
                    colorText: inputStyle.color,
                    colorTextPlaceholder: placeholderColor,
                    colorIcon: placeholderColor,
                  },
                });
              }}
            />
          ) : null}
          {appearance != null ? (
            <DeferredIntentElementsProvider
              amount={Math.max(amount, MIN_STRIPE_AMOUNT_CENTS)}
              appearance={appearance}
              paymentMethodTypes={paymentMethodTypes}
            >
              <ElementsBridge onReady={onReady} />
              <PaymentElement
                options={{
                  fields: { billingDetails: { address: { postalCode: "never", country: "never" } } },
                  layout: "tabs",
                }}
              />
            </DeferredIntentElementsProvider>
          ) : null}
        </>
      )}
    </Fieldset>
  );
};

const DeferredIntentElementsProvider = ({
  children,
  amount,
  appearance,
  paymentMethodTypes,
}: {
  children: React.ReactNode;
  amount: number;
  appearance: Appearance;
  paymentMethodTypes: string[];
}) => {
  const [stripePromise] = React.useState(getStripeInstance);
  const font = useFont();
  const stripeFonts = [{ family: font.name, src: `url(${font.url})` }];

  const options: StripeElementsOptionsMode = {
    fonts: stripeFonts,
    mode: "payment",
    amount,
    currency: "usd",
    paymentMethodTypes,
    appearance,
  };

  return (
    <Elements stripe={stripePromise} options={options}>
      {children}
    </Elements>
  );
};

export const StripeElementsProvider = ({ children }: { children: React.ReactNode }) => {
  const [stripePromise] = React.useState(getStripeInstance);
  const font = useFont();

  const stripeFonts = [{ family: font.name, src: `url(${font.url})` }];

  return (
    <Elements stripe={stripePromise} options={{ fonts: stripeFonts }}>
      {children}
    </Elements>
  );
};
