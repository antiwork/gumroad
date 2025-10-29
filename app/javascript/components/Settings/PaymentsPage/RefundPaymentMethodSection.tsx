import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import { StripeCardElement } from "@stripe/stripe-js";

import { Button } from "$app/components/Button";
import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";
import { Icon } from "$app/components/Icons";
import { RefundCardData } from "$app/components/server-components/Settings/PaymentsPage";

type Props = {
  refundCard: SavedCreditCard | null;
  isFormDisabled: boolean;
  // Props following debit card pattern
  refundCardData: RefundCardData | null;
  setRefundCard: (refundCard: RefundCardData | null) => void;
  nameOnCard?: string;
  onNameOnCardChange?: (name: string) => void;
};

export const RefundPaymentMethodSection = ({
  refundCard,
  isFormDisabled,
  refundCardData,
  setRefundCard,
  nameOnCard = "",
  onNameOnCardChange
}: Props) => {
  const [status, setStatus] = React.useState<"removing" | "removed" | null>(null);

  // Remove card functionality - clears data for main form submission
  const remove = () => {
    setRefundCard(null);
    setStatus("removed");
  };

  // Handle card element ready (following debit card pattern)
  const handleCardReady = (element: StripeCardElement) => {
    setRefundCard({ type: "new", element });
  };

  // Handle name on card change
  const handleNameChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (onNameOnCardChange) {
      onNameOnCardChange(e.target.value);
    }
  };

  // If card is removed, don't render anything
  if (status === "removed") return null;

  // If card exists, show saved card display
  if (refundCard) {
    return (
      <section className="p-4! md:p-8!">
        <header>
          <h2>Refund payment method</h2>
          <p>Add a card to automatically cover refunds when your Gumroad balance is too low. You'll only be charged if your balance can't cover the refund amount.</p>
          <a href={Routes.help_center_root_path()} target="_blank" rel="noreferrer">
            Learn more
          </a>
        </header>
        <div className="paragraphs">
          <div className="input read-only" aria-label="Saved refund credit card">
            <Icon name="outline-credit-card" />
            <span>{refundCard.number}</span>
            <span style={{ marginLeft: "auto" }}>{refundCard.expiration_date}</span>
          </div>
          {!isFormDisabled && (
            <Button outline color="danger" onClick={remove} disabled={status === "removing"}>
              {status === "removing" ? "Removing..." : "Remove refund card"}
            </Button>
          )}
        </div>
      </section>
    );
  }

  // If no card, show input form
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
        <fieldset>
          <legend>
            <label htmlFor="refund-cardholder-name">Name on card</label>
          </legend>
          <input
            type="text"
            placeholder="John Doe"
            id="refund-cardholder-name"
            value={nameOnCard}
            disabled={isFormDisabled}
            onChange={handleNameChange}
          />
        </fieldset>
        <div className="mt-4">
          <CreditCardInput
            disabled={isFormDisabled}
            savedCreditCard={null}
            useSavedCard={false}
            setUseSavedCard={() => {}}
            onReady={handleCardReady}
            onChange={(evt) => {
              // Handle card validation (following debit card pattern)
              if (evt.error && refundCardData?.type === "new") {
                setRefundCard({ type: "new", element: refundCardData.element });
              }
            }}
          />
        </div>
      </div>
    </section>
  );
};

export default RefundPaymentMethodSection;
