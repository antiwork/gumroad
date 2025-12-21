import { CardElement, Elements, useElements, useStripe } from "@stripe/react-stripe-js";
import { Stripe, StripeElementStyleVariant } from "@stripe/stripe-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { getStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
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

const RefundPaymentMethodForm = ({
  refundPaymentMethod,
  isFormDisabled,
  onSuccess,
}: Props & { onSuccess: () => void }) => {
  const stripe = useStripe();
  const elements = useElements();
  const [nameOnCard, setNameOnCard] = React.useState(refundPaymentMethod.name_on_card || "");
  const [zipCode, setZipCode] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [savedCard, setSavedCard] = React.useState(refundPaymentMethod.credit_card);
  const [isEditing, setIsEditing] = React.useState(!refundPaymentMethod.enabled);
  const [stripeStyle, setStripeStyle] = React.useState<null | StripeElementStyleVariant>(null);

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
          address: {
            postal_code: zipCode,
          },
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
    <section id="refund-payment-method" className="p-4! md:p-8!">
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

      <div className="flex flex-col gap-5">
        {savedCard && !isEditing ? (
          <div>
            <div className="saved-card-display flex flex-col gap-4">
              <div>
                <label className="mb-2 block" htmlFor="saved_name_on_card">
                  Name on card
                </label>
                <div className="input read-only" id="saved_name_on_card">
                  {nameOnCard}
                </div>
              </div>
              <div>
                <label className="mb-2 block" htmlFor="saved_card_number">
                  Card information
                </label>
                <div className="input read-only" aria-label="Saved credit card">
                  <Icon name="outline-credit-card" />
                  <span>•••• •••• •••• {savedCard.visual}</span>
                  <span style={{ marginLeft: "auto" }}>
                    {savedCard.expiry_month.toString().padStart(2, "0")}/{formatExpiryYear(savedCard.expiry_year)}
                  </span>
                </div>
              </div>
              {!isFormDisabled ? (
                <div className="flex gap-4">
                  <Button outline onClick={() => setIsEditing(true)} disabled={isSubmitting}>
                    Change card
                  </Button>
                  <Button outline color="danger" onClick={handleRemove} disabled={isSubmitting}>
                    Remove card
                  </Button>
                </div>
              ) : null}
            </div>
          </div>
        ) : (
          <>
            <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
              <fieldset>
                <legend>
                  <label htmlFor="refund_name_on_card">Name on card</label>
                </legend>
                <input
                  type="text"
                  id="refund_name_on_card"
                  placeholder="John Doe"
                  value={nameOnCard}
                  onChange={(e) => setNameOnCard(e.target.value)}
                  disabled={isFormDisabled || isSubmitting}
                />
              </fieldset>
              <fieldset>
                <legend>
                  <label htmlFor="refund_zip_code">ZIP / Postal code</label>
                </legend>
                <input
                  type="text"
                  id="refund_zip_code"
                  placeholder="12345"
                  value={zipCode}
                  onChange={(e) => setZipCode(e.target.value)}
                  disabled={isFormDisabled || isSubmitting}
                />
              </fieldset>
            </div>
            <fieldset>
              <legend>
                <label htmlFor="refund_card_info">Card information</label>
              </legend>
              <div
                className="stripe-card-element-wrapper input"
                style={{
                  height: "auto",
                  padding: "0.75rem",
                  display: "flex",
                  alignItems: "center",
                  gap: "0.5rem",
                }}
              >
                {stripeStyle === null ? (
                  <input
                    type="text"
                    style={{ position: "absolute", visibility: "hidden" }}
                    ref={(el) => {
                      if (el == null) return;
                      const inputStyle = window.getComputedStyle(el);
                      const color = getCssVariable("color").split(" ").join(",");
                      const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                      setStripeStyle({
                        fontFamily: inputStyle.fontFamily,
                        color: inputStyle.color,
                        iconColor: placeholderColor,
                        "::placeholder": { color: placeholderColor },
                      });
                    }}
                  />
                ) : null}
                <svg
                  width="20"
                  height="16"
                  viewBox="0 0 20 16"
                  fill="none"
                  xmlns="http://www.w3.org/2000/svg"
                  style={{ flexShrink: 0, opacity: 0.5 }}
                >
                  <path
                    d="M0.75 5.75H18.75M4.75 10.75H5.75M9.75 10.75H10.75M3.75 14.75H15.75C17.4069 14.75 18.75 13.4069 18.75 11.75V3.75C18.75 2.09315 17.4069 0.75 15.75 0.75H3.75C2.09315 0.75 0.75 2.09315 0.75 3.75V11.75C0.75 13.4069 2.09315 14.75 3.75 14.75Z"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
                <div style={{ flex: 1 }}>
                  <CardElement
                    options={{
                      style: {
                        base: {
                          fontSize: "16px",
                          ...(stripeStyle || {}),
                        },
                      },
                      hideIcon: true,
                      hidePostalCode: true,
                      disabled: isFormDisabled || isSubmitting,
                    }}
                  />
                </div>
              </div>
            </fieldset>
            {!isFormDisabled ? (
              <div className="actions">
                <button
                  type="button"
                  className="button primary"
                  onClick={handleSubmit}
                  disabled={isSubmitting || !nameOnCard || !zipCode}
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
  const [stripePromise, setStripePromise] = React.useState<Promise<Stripe | null> | null>(null);
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
