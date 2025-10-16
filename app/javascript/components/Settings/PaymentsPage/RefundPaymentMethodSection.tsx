import { StripeCardElement, StripeCardElementChangeEvent } from "@stripe/stripe-js";
import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";

import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";
import type { RefundPaymentMethodCardData } from "$app/components/Settings/PaymentsPage/types";

const selectionEquals = (a: RefundPaymentMethodCardData, b: RefundPaymentMethodCardData): boolean => {
  if (a === undefined && b === undefined) return true;
  if (!a || !b) return false;
  if (a.type !== b.type) return false;
  if (a.type === "new" && b.type === "new") {
    return a.element === b.element;
  }
  return true;
};

const RefundPaymentMethodSection = ({
  isFormDisabled,
  nameOnCard,
  setNameOnCard,
  savedCard,
  setCard,
  helpUrl,
}: {
  isFormDisabled: boolean;
  nameOnCard: string;
  setNameOnCard: (name: string) => void;
  savedCard: SavedCreditCard | null;
  setCard: (card: RefundPaymentMethodCardData) => void;
  helpUrl: string;
}) => {
  const [useSavedCard, setUseSavedCard] = React.useState(Boolean(savedCard));
  const [cardElement, setCardElement] = React.useState<StripeCardElement | null>(null);
  const [cardComplete, setCardComplete] = React.useState(false);
  const previousSelectionRef = React.useRef<RefundPaymentMethodCardData>();

  const shouldUseSavedCard = Boolean(savedCard) && useSavedCard;

  React.useEffect(() => {
    if (!savedCard) {
      setUseSavedCard(false);
    }
  }, [savedCard]);

  React.useEffect(() => {
    let nextSelection: RefundPaymentMethodCardData;
    if (useSavedCard && savedCard) {
      nextSelection = { type: "saved" };
    } else if (cardElement && cardComplete) {
      nextSelection = { type: "new", element: cardElement };
    } else {
      nextSelection = undefined;
    }

    if (!selectionEquals(previousSelectionRef.current, nextSelection)) {
      previousSelectionRef.current = nextSelection;
      setCard(nextSelection);
    }
  }, [useSavedCard, cardElement, savedCard, cardComplete, setCard]);

  const handleCardChange = React.useCallback(
    (evt: StripeCardElementChangeEvent) => {
      setCardComplete(evt.complete);
      if (!evt.complete) {
        previousSelectionRef.current = undefined;
        setCard(undefined);
      }
    },
    [setCard],
  );

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Refund payment method</h2>
        <p className="text-muted text-sm leading-relaxed">
          Add a card to automatically cover refunds when your Gumroad balance is too low. You&apos;ll only be charged if
          your balance can&apos;t cover the refund amount.{" "}
          <a href={helpUrl} target="_blank" rel="noreferrer">
            Learn more
          </a>
          .
        </p>
      </header>
      <section className="grid gap-8">
        <fieldset className="w-full">
          <label htmlFor="refund-payment-method-name">Name on card</label>
          <input
            id="refund-payment-method-name"
            type="text"
            value={nameOnCard}
            onChange={(evt) => setNameOnCard(evt.target.value)}
            disabled={isFormDisabled}
            placeholder="John Doe"
            autoComplete="cc-name"
          />
        </fieldset>
        <div className="min-w-0">
          <CreditCardInput
            disabled={isFormDisabled}
            savedCreditCard={savedCard}
            onReady={setCardElement}
            useSavedCard={shouldUseSavedCard}
            setUseSavedCard={setUseSavedCard}
            onChange={handleCardChange}
          />
        </div>
      </section>
    </section>
  );
};

export default RefundPaymentMethodSection;
