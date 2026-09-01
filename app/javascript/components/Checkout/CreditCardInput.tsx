import { CreditCard } from "@boxicons/react";
import { CardElement, Elements } from "@stripe/react-stripe-js";
import { StripeCardElement, StripeCardElementChangeEvent } from "@stripe/stripe-js";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import { getStripeInstance } from "$app/utils/stripe_loader";

import {
  getCheckoutCardElementStyle,
  useCheckoutTheme,
  useCheckoutStripeFonts,
  useNeutralCheckoutThemeColors,
} from "$app/components/Checkout/checkoutTheme";
import { useFont } from "$app/components/DesignSettings";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { LinkButton } from "$app/components/ui/LinkButton";

export const CreditCardInput = ({
  disabled,
  savedCreditCard,
  invalid,
  onReady,
  useSavedCard,
  setUseSavedCard,
  onChange,
  enableLink = false,
}: {
  disabled?: boolean;
  savedCreditCard: SavedCreditCard | null;
  invalid?: boolean;
  onReady: (element: StripeCardElement) => void;
  useSavedCard: boolean;
  setUseSavedCard: (value: boolean) => void;
  onChange?: (evt: StripeCardElementChangeEvent) => void;
  enableLink?: boolean;
}) => {
  const checkoutTheme = useCheckoutTheme();
  const neutralColors = useNeutralCheckoutThemeColors();
  const font = useFont();
  const baseStripeStyle = checkoutTheme
    ? getCheckoutCardElementStyle(checkoutTheme)
    : {
        fontFamily: `${font.name}, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`,
        color: neutralColors.text,
        iconColor: neutralColors.placeholder,
        "::placeholder": { color: neutralColors.placeholder },
      };

  return (
    <Fieldset state={invalid ? "danger" : undefined}>
      <FieldsetTitle>
        <Label>Card information</Label>
        {savedCreditCard ? (
          <LinkButton className="font-normal" disabled={disabled} onClick={() => setUseSavedCard(!useSavedCard)}>
            {useSavedCard ? "Use a different card?" : "Use saved card"}
          </LinkButton>
        ) : null}
      </FieldsetTitle>
      {savedCreditCard && useSavedCard ? (
        <InputGroup readOnly aria-label="Saved credit card">
          <CreditCard className="size-5" />
          <span>{savedCreditCard.number}</span>
          <span style={{ marginLeft: "auto" }}>{savedCreditCard.expiration_date}</span>
        </InputGroup>
      ) : (
        <InputGroup disabled={disabled} aria-label="Card information" aria-invalid={invalid}>
          <StripeElementsProvider>
            <CardElement
              className="flex-1"
              options={{
                style: { base: baseStripeStyle ?? {} },
                hidePostalCode: true,
                disabled: disabled ?? false,
                disableLink: !enableLink,
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
  const stripeFonts = useCheckoutStripeFonts(font);

  return (
    <Elements stripe={stripePromise} options={{ fonts: stripeFonts }}>
      {children}
    </Elements>
  );
};
