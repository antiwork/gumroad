import { CreditCard } from "@boxicons/react";
import { CardElement } from "@stripe/react-stripe-js";
import { StripeCardElement, StripeElementStyleVariant } from "@stripe/stripe-js";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import type { PayoutDebitCardData } from "$app/types/payments";
import { getCssVariable } from "$app/utils/styles";

import { StripeElementsProvider } from "$app/components/Checkout/CreditCardInput";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";

export const PayoutCreditCard = ({
  saved_card,
  is_form_disabled,
  setDebitCard,
}: {
  saved_card: SavedCreditCard | null;
  is_form_disabled: boolean;
  setDebitCard: (debitCard: PayoutDebitCardData) => void;
}) => {
  const [useSavedCard, setUseSavedCard] = React.useState(!!saved_card);
  const [cardElement, setCardElement] = React.useState<StripeCardElement | null>(null);
  const [baseStripeStyle, setBaseStripeStyle] = React.useState<null | StripeElementStyleVariant>(null);

  React.useEffect(() => {
    setDebitCard(useSavedCard ? { type: "saved" } : cardElement ? { type: "new", element: cardElement } : undefined);
  }, [useSavedCard, cardElement]);

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label>Card information</Label>
        {saved_card ? (
          <button
            className="cursor-pointer font-normal underline all-unset"
            disabled={is_form_disabled}
            onClick={() => setUseSavedCard(!useSavedCard)}
          >
            {useSavedCard ? "Use a different card?" : "Use saved card"}
          </button>
        ) : null}
      </FieldsetTitle>
      {saved_card && useSavedCard ? (
        <InputGroup readOnly aria-label="Saved credit card">
          <CreditCard className="size-5" />
          <span>{saved_card.number}</span>
          <span style={{ marginLeft: "auto" }}>{saved_card.expiration_date}</span>
        </InputGroup>
      ) : (
        <InputGroup disabled={is_form_disabled} aria-label="Card information">
          {baseStripeStyle == null ? (
            <input
              ref={(el) => {
                if (el == null) return;
                const inputStyle = window.getComputedStyle(el);
                const color = getCssVariable("color").split(" ").join(",");
                const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                const sanitizedFontFamily = inputStyle.fontFamily.replace(/\\[0-9a-fA-F]+\s?/gu, "");
                setBaseStripeStyle({
                  fontFamily: sanitizedFontFamily || "sans-serif",
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
                disabled: is_form_disabled,
                hideIcon: true,
              }}
              onReady={setCardElement}
            />
          </StripeElementsProvider>
        </InputGroup>
      )}
    </Fieldset>
  );
};

export default PayoutCreditCard;
