import { StripeCardElement } from "@stripe/stripe-js";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { SavedCreditCard } from "$app/parsers/card";
import { register } from "$app/utils/serverComponentUtil";

import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";
import { PayoutDebitCardData } from "$app/components/server-components/Settings/PaymentsPage";

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
  React.useEffect(() => {
    setDebitCard(useSavedCard ? { type: "saved" } : cardElement ? { type: "new", element: cardElement } : undefined);
  }, [useSavedCard, cardElement]);

  return (
    <CreditCardInput
      disabled={is_form_disabled}
      savedCreditCard={saved_card}
      onReady={setCardElement}
      useSavedCard={useSavedCard}
      setUseSavedCard={setUseSavedCard}
    />
  );
};

export default register({ component: PayoutCreditCard, propParser: createCast() });
