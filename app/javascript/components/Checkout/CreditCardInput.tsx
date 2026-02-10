import { CardElement, Elements } from "@stripe/react-stripe-js";
import { StripeCardElement, StripeElementStyleVariant, StripeCardElementChangeEvent } from "@stripe/stripe-js";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import { getStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import { useFont } from "$app/components/DesignSettings";
import { Icon } from "$app/components/Icons";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

export const CreditCardInput = ({
  disabled,
  savedCreditCard,
  invalid,
  onReady,
  useSavedCard,
  setUseSavedCard,
  onChange,
}: {
  disabled?: boolean;
  savedCreditCard: SavedCreditCard | null;
  invalid?: boolean;
  onReady: (element: StripeCardElement) => void;
  useSavedCard: boolean;
  setUseSavedCard: (value: boolean) => void;
  onChange?: (evt: StripeCardElementChangeEvent) => void;
}) => {
  // Actually set font family, size, and color and determined on the first render based on a ghost div that is unmounted
  // as soon as the measurement is performed.
  const [baseStripeStyle, setBaseStripeStyle] = React.useState<null | StripeElementStyleVariant>(null);

  return (
    <Fieldset state={invalid ? "danger" : undefined}>
      <FieldsetTitle>
        <Label>Card information</Label>
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
          <Icon name="outline-credit-card" />
          <span>{savedCreditCard.number}</span>
          <span style={{ marginLeft: "auto" }}>{savedCreditCard.expiration_date}</span>
        </InputGroup>
      ) : (
        <InputGroup disabled={disabled} aria-label="Card information" aria-invalid={invalid}>
          {baseStripeStyle == null ? (
            <input
              ref={(el) => {
                if (el == null) return;
                const inputStyle = window.getComputedStyle(el);
                const color = getCssVariable("color").split(" ").join(",");
                const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                setBaseStripeStyle({
                  fontFamily: inputStyle.fontFamily,
                  color: inputStyle.color,
                  iconColor: placeholderColor,
                  "::placeholder": { color: placeholderColor },
                });
              }}
            />
          ) : null}
          <StripeElementsProvider>
            <CardElement
              className="flex-1"
              options={{
                style: { base: baseStripeStyle ?? {} },
                hidePostalCode: true,
                disabled: disabled ?? false,
                disableLink: true,
                hideIcon: true,
              }}
              onReady={onReady}
              {...(onChange ? { onChange } : {})}
            />
          </StripeElementsProvider>
        </InputGroup>
      )}
    </Fieldset>
  );
};

export const StripeElementsProvider = ({ children }: { children: React.ReactNode }) => {
  const [stripePromise] = React.useState(getStripeInstance);
  const font = useFont();

  // Since Stripe Elements are rendered in iframes, we need to explicitly pass in the font source & input styles
  const stripeFonts = [{ family: font.name, src: `url(${font.url})` }];

  return (
    <Elements stripe={stripePromise} options={{ fonts: stripeFonts }}>
      {children}
    </Elements>
  );
};
