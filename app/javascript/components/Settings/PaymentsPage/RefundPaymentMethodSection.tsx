import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import { StripeCardElement } from "@stripe/stripe-js";

import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";

type Props = {
  refundCard: SavedCreditCard | null;
  isFormDisabled: boolean;
};

export const RefundPaymentMethodSection = ({ refundCard, isFormDisabled }: Props) => {
  const [useSavedCard, setUseSavedCard] = React.useState(!!refundCard);
  const [cardElement, setCardElement] = React.useState<StripeCardElement | null>(null);

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Refund payment method</h2>
        <p>Add a card to automatically cover refunds when your Gumroad balance is too low. You'll only be charged if your balance can't cover the refund amount.</p>
        <a href="/help" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>

      <div className="mt-4">
        <label htmlFor="cardholder-name">Name on card</label>
        <div className="input">
          <input
            id="cardholder-name"
            type="text"
            placeholder="John Doe"
            disabled={isFormDisabled}
          />
        </div>
        <div className="mt-4">
          <CreditCardInput
            disabled={isFormDisabled}
            savedCreditCard={refundCard}
            useSavedCard={useSavedCard}
            setUseSavedCard={setUseSavedCard}
            onReady={setCardElement}
          />
        </div>
      </div>
    </section>
  );
};

export default RefundPaymentMethodSection;
