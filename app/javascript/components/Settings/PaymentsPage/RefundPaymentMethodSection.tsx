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

  refundCardData: RefundCardData | null;
  setRefundCard: (refundCard: RefundCardData | null) => void;
  nameOnCard?: string;
  onNameOnCardChange?: (name: string) => void;
  onSave: (action: "save" | "remove") => void;
  isSaving?: boolean;
  errorMessage?: string | null;
};

export const RefundPaymentMethodSection = ({
  refundCard,
  isFormDisabled,
  refundCardData,
  setRefundCard,
  nameOnCard = "",
  onNameOnCardChange,
  onSave,
  isSaving = false,
  errorMessage = null,
}: Props) => {
  const remove = () => setRefundCard(null);

  const handleCardReady = (element: StripeCardElement) => {
    setRefundCard({ type: "new", element });
  };

  const handleNameChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    if (onNameOnCardChange) {
      onNameOnCardChange(e.target.value);
    }
  };

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
            <Button
              outline
              color="danger"
              onClick={() => {
                remove();
                onSave("remove");
              }}
              disabled={isSaving}
            >
              {isSaving ? "Removing..." : "Remove refund card"}
            </Button>
          )}
        </div>
      </section>
    );
  }

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
              if (evt.error && refundCardData?.type === "new") {
                setRefundCard({ type: "new", element: refundCardData.element });
              }
            }}
          />
          {errorMessage ? (
            <div className="mt-2" role="status">
              <small className="text-danger">{errorMessage}</small>
            </div>
          ) : null}
          <div className="mt-4">
            <Button
              onClick={() => onSave("save")}
              disabled={isFormDisabled || isSaving}
            >
              {isSaving ? "Saving..." : "Save refund card"}
            </Button>
          </div>
        </div>
      </div>
    </section>
  );
};

export default RefundPaymentMethodSection;
