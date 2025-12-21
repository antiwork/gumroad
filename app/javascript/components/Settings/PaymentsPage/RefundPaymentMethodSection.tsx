import { CardElement, Elements, useElements, useStripe } from "@stripe/react-stripe-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";

export type RefundPaymentMethodProps = {
  enabled: boolean;
  name_on_card: string | null;
  credit_card: {
    visual: string;
    card_type: string;
    expiry_month: number;
    expiry_year: number;
  } | null;
};

type Props = {
  refundPaymentMethod: RefundPaymentMethodProps;
  isFormDisabled: boolean;
};

import { getStripeInstance } from "$app/utils/stripe_loader";

const RefundPaymentMethodForm = ({
  refundPaymentMethod,
  isFormDisabled,
  onSuccess,
}: Props & { onSuccess: () => void }) => {
  const stripe = useStripe();
  const elements = useElements();
  const [nameOnCard, setNameOnCard] = React.useState(refundPaymentMethod.name_on_card || "");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [savedCard, setSavedCard] = React.useState(refundPaymentMethod.credit_card);
  const [isEditing, setIsEditing] = React.useState(!refundPaymentMethod.enabled);

  const handleSubmit = asyncVoid(async () => {
    if (!stripe || !elements) return;

    const cardElement = elements.getElement(CardElement);
    if (!cardElement) return;

    setIsSubmitting(true);

    try {
      const { paymentMethod, error } = await stripe.createPaymentMethod({
        type: "card",
        card: cardElement,
        billing_details: {
          name: nameOnCard,
        },
      });

      if (error) {
        showAlert(error.message || "Card verification failed", "error");
        setIsSubmitting(false);
        return;
      }

      const response = await request({
        method: "POST",
        url: Routes.settings_refund_funding_path(),
        accept: "json",
        data: {
          stripe_payment_method_id: paymentMethod.id,
          name_on_card: nameOnCard,
          card_data_handling_mode: "stripejs.0",
        },
      });

      const result = cast<{ success: boolean; error?: string; credit_card?: RefundPaymentMethodProps["credit_card"] }>(
        await response.json(),
      );

      if (result.success && result.credit_card) {
        showAlert("Refund payment method saved successfully!", "success");
        setSavedCard(result.credit_card);
        setIsEditing(false);
        onSuccess();
      } else {
        showAlert(result.error || "Failed to save card", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred. Please try again.", "error");
    }

    setIsSubmitting(false);
  });

  const handleRemove = asyncVoid(async () => {
    setIsSubmitting(true);

    try {
      const response = await request({
        method: "DELETE",
        url: Routes.settings_refund_funding_path(),
        accept: "json",
      });

      const result = cast<{ success: boolean; error?: string }>(await response.json());

      if (result.success) {
        showAlert("Refund payment method removed", "success");
        setSavedCard(null);
        setNameOnCard("");
        setIsEditing(true);
        onSuccess();
      } else {
        showAlert(result.error || "Failed to remove card", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred. Please try again.", "error");
    }

    setIsSubmitting(false);
  });

  const formatExpiryYear = (year: number) => year.toString().slice(-2);

  return (
    <section>
      <header>
        <h2>Refund payment method</h2>
        <p className="text-muted">
          Add a card to automatically cover refunds when your Gumroad balance is too low. You'll only be charged if your
          balance can't cover the refund amount.{" "}
          <a href="/help/article/refunds" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </p>
      </header>

      <div className="paragraphs">
        {savedCard && !isEditing ? (
          <div className="input-with-label">
            <div className="saved-card-display">
              <div className="input">
                <label htmlFor="saved_name_on_card">Name on card</label>
                <input type="text" id="saved_name_on_card" value={nameOnCard} disabled className="disabled" />
              </div>
              <div className="input">
                <label htmlFor="saved_card_number">Card information</label>
                <input
                  type="text"
                  id="saved_card_number"
                  value={`•••• •••• •••• ${savedCard.visual}    ${savedCard.expiry_month.toString().padStart(2, "0")}/${formatExpiryYear(savedCard.expiry_year)}`}
                  disabled
                  className="disabled"
                />
              </div>
              {!isFormDisabled ? (
                <div className="actions" style={{ marginTop: "0.5rem" }}>
                  <button
                    type="button"
                    className="link"
                    onClick={() => setIsEditing(true)}
                    disabled={isSubmitting}
                    style={{ marginRight: "1rem" }}
                  >
                    Change card
                  </button>
                  <button type="button" className="link danger" onClick={handleRemove} disabled={isSubmitting}>
                    Remove card
                  </button>
                </div>
              ) : null}
            </div>
          </div>
        ) : (
          <>
            <div className="input">
              <label htmlFor="refund_name_on_card">Name on card</label>
              <input
                type="text"
                id="refund_name_on_card"
                placeholder="John Doe"
                value={nameOnCard}
                onChange={(e) => setNameOnCard(e.target.value)}
                disabled={isFormDisabled || isSubmitting}
              />
            </div>
            <div className="input">
              <label htmlFor="refund_card_info">Card information</label>
              <div
                className="stripe-card-element-wrapper"
                style={{ padding: "0.75rem", border: "1px solid #ccc", borderRadius: "4px" }}
              >
                <CardElement
                  options={{
                    style: {
                      base: {
                        fontSize: "16px",
                        color: "#424770",
                        "::placeholder": {
                          color: "#aab7c4",
                        },
                      },
                    },
                    disabled: isFormDisabled || isSubmitting,
                  }}
                />
              </div>
            </div>
            {!isFormDisabled ? (
              <div className="actions">
                <button
                  type="button"
                  className="button primary"
                  onClick={handleSubmit}
                  disabled={isSubmitting || !nameOnCard}
                >
                  {isSubmitting ? "Saving..." : savedCard ? "Update card" : "Save card"}
                </button>
                {savedCard ? (
                  <button
                    type="button"
                    className="button"
                    onClick={() => setIsEditing(false)}
                    disabled={isSubmitting}
                    style={{ marginLeft: "0.5rem" }}
                  >
                    Cancel
                  </button>
                ) : null}
              </div>
            ) : null}
          </>
        )}
      </div>
    </section>
  );
};

export const RefundPaymentMethodSection = ({ refundPaymentMethod, isFormDisabled }: Props) => {
  const [stripePromise, setStripePromise] = React.useState<Promise<any> | null>(null);
  const handleSuccess = () => undefined;

  React.useEffect(() => {
    setStripePromise(getStripeInstance());
  }, []);

  if (!stripePromise) {
    return <div>Loading...</div>;
  }

  return (
    <Elements stripe={stripePromise}>
      <RefundPaymentMethodForm
        refundPaymentMethod={refundPaymentMethod}
        isFormDisabled={isFormDisabled}
        onSuccess={handleSuccess}
      />
    </Elements>
  );
};

export default RefundPaymentMethodSection;

