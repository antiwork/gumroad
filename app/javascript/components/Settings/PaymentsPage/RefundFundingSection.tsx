import { CardElement, Elements, useElements, useStripe } from "@stripe/react-stripe-js";
import * as React from "react";

import { asyncVoid } from "$app/utils/promise";
import { getStripeInstance } from "$app/utils/stripe_loader";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

type RefundFundingCard = {
  visual: string;
  card_type: string;
  expiry_month: number;
  expiry_year: number;
} | null;

type RefundFundingSectionProps = {
  refundFundingCard: RefundFundingCard;
  nameOnCard: string | null;
  isFormDisabled: boolean;
};

const CardForm = ({
  onSuccess,
  onCancel,
}: {
  onSuccess: (card: RefundFundingCard, name: string) => void;
  onCancel: () => void;
}) => {
  const stripe = useStripe();
  const elements = useElements();
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [nameOnCard, setNameOnCard] = React.useState("");

  const handleSubmit = async () => {
    if (!stripe || !elements) return;

    if (!nameOnCard.trim()) {
      setError("Name on card is required");
      return;
    }

    setIsSubmitting(true);
    setError(null);

    const cardElement = elements.getElement(CardElement);
    if (!cardElement) {
      setError("Card element not found");
      setIsSubmitting(false);
      return;
    }

    const { error: stripeError, paymentMethod } = await stripe.createPaymentMethod({
      type: "card",
      card: cardElement,
      billing_details: {
        name: nameOnCard.trim(),
      },
    });

    if (stripeError) {
      setError(stripeError.message || "An error occurred");
      setIsSubmitting(false);
      return;
    }

    try {
      const response = await fetch(Routes.settings_refund_funding_path(), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || "",
        },
        body: JSON.stringify({
          stripe_payment_method_id: paymentMethod.id,
          name_on_card: nameOnCard.trim(),
          card_data_handling_mode: "stripejs.0",
        }),
      });

      const data = await response.json();

      if (data.success) {
        onSuccess(data.credit_card, nameOnCard.trim());
        showAlert("Refund payment method saved successfully!", "success");
      } else {
        setError(data.error || "Failed to save card");
      }
    } catch {
      setError("Failed to save card. Please try again.");
    }

    setIsSubmitting(false);
  };

  return (
    <div className="flex flex-col gap-4">
      <fieldset>
        <label htmlFor="refund-name-on-card">Name on card</label>
        <input
          id="refund-name-on-card"
          type="text"
          placeholder="John Doe"
          value={nameOnCard}
          onChange={(e) => setNameOnCard(e.target.value)}
        />
      </fieldset>
      <fieldset>
        <label>Card information</label>
        <div className="flex items-center gap-2 rounded border border-black bg-white px-3 py-2">
          <Icon name="outline-credit-card" />
          <div className="flex-1">
            <CardElement
              options={{
                style: {
                  base: {
                    fontSize: "16px",
                    color: "#000",
                    "::placeholder": { color: "#9ca3af" },
                  },
                  invalid: { color: "#dc2626" },
                },
                hidePostalCode: true,
              }}
            />
          </div>
        </div>
      </fieldset>
      {error ? <small className="text-red">{error}</small> : null}
      <div className="flex gap-2">
        <Button type="button" onClick={asyncVoid(handleSubmit)} disabled={isSubmitting || !stripe}>
          {isSubmitting ? "Saving..." : "Save card"}
        </Button>
        <Button type="button" outline onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </div>
  );
};

const SavedCard = ({
  card,
  nameOnCard,
  onRemove,
  isRemoving,
  isFormDisabled,
}: {
  card: NonNullable<RefundFundingCard>;
  nameOnCard: string | null;
  onRemove: () => void;
  isRemoving: boolean;
  isFormDisabled: boolean;
}) => (
  <div className="flex flex-col gap-4">
    <fieldset>
      <label>Name on card</label>
      <input type="text" value={nameOnCard || "Creator name"} disabled className="bg-gray-50" />
    </fieldset>
    <fieldset>
      <label>Card information</label>
      <div className="flex items-center justify-between rounded border border-black bg-white px-3 py-2">
        <div className="flex items-center gap-2">
          <Icon name="outline-credit-card" />
          <span>{card.visual}</span>
        </div>
        <span className="text-gray-500">
          {String(card.expiry_month).padStart(2, "0")}/{String(card.expiry_year).slice(-2)}
        </span>
      </div>
    </fieldset>
    <div>
      <Button type="button" outline onClick={onRemove} disabled={isFormDisabled || isRemoving}>
        {isRemoving ? "Removing..." : "Remove card"}
      </Button>
    </div>
  </div>
);

const RefundFundingSection = ({
  refundFundingCard,
  nameOnCard: initialNameOnCard,
  isFormDisabled,
}: RefundFundingSectionProps) => {
  const [card, setCard] = React.useState<RefundFundingCard>(refundFundingCard);
  const [nameOnCard, setNameOnCard] = React.useState<string | null>(initialNameOnCard);
  const [isAddingCard, setIsAddingCard] = React.useState(false);
  const [isRemoving, setIsRemoving] = React.useState(false);
  const [stripePromise] = React.useState(getStripeInstance);

  const handleRemove = async () => {
    // eslint-disable-next-line no-alert
    if (!confirm("Are you sure you want to remove your refund payment method?")) return;

    setIsRemoving(true);
    try {
      const response = await fetch(Routes.settings_refund_funding_path(), {
        method: "DELETE",
        headers: {
          "X-CSRF-Token": document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || "",
        },
      });

      const data = await response.json();
      if (data.success) {
        setCard(null);
        setNameOnCard(null);
        showAlert("Refund payment method removed.", "success");
      }
    } catch {
      showAlert("Failed to remove card. Please try again.", "error");
    }
    setIsRemoving(false);
  };

  return (
    <section className="p-4! md:p-8!" id="refund-payment-method">
      <header>
        <h2>Refund payment method</h2>
        <p className="text-muted">
          Add a card to automatically cover refunds when your Gumroad balance is too low. You'll only be charged if your
          balance can't cover the refund amount.{" "}
          <a href="https://help.gumroad.com/article/refunds" target="_blank" rel="noopener noreferrer">
            Learn more
          </a>
        </p>
      </header>
      <div className="flex flex-col gap-4">
        {card ? (
          <SavedCard
            card={card}
            nameOnCard={nameOnCard}
            onRemove={asyncVoid(handleRemove)}
            isRemoving={isRemoving}
            isFormDisabled={isFormDisabled}
          />
        ) : isAddingCard ? (
          <Elements stripe={stripePromise}>
            <CardForm
              onSuccess={(newCard, newName) => {
                setCard(newCard);
                setNameOnCard(newName);
                setIsAddingCard(false);
              }}
              onCancel={() => setIsAddingCard(false)}
            />
          </Elements>
        ) : (
          <Button onClick={() => setIsAddingCard(true)} disabled={isFormDisabled}>
            Add card
          </Button>
        )}
      </div>
    </section>
  );
};

export default RefundFundingSection;
