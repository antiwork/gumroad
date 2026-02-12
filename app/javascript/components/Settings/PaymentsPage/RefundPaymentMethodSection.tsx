import { CardElement, Elements, useElements, useStripe } from "@stripe/react-stripe-js";
import { StripeElementStyleVariant } from "@stripe/stripe-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { getStripeInstance } from "$app/utils/stripe_loader";
import { getCssVariable } from "$app/utils/styles";

import { Button } from "$app/components/Button";
import { useFont } from "$app/components/DesignSettings";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

export type RefundFundingCard = {
  visual: string;
  card_type: string;
  expiry_month: number;
  expiry_year: number;
} | null;

const RefundPaymentMethodForm = ({
  initialCard,
  isFormDisabled,
}: {
  initialCard: RefundFundingCard;
  isFormDisabled: boolean;
}) => {
  const stripe = useStripe();
  const elements = useElements();
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [savedCard, setSavedCard] = React.useState(initialCard);
  const [isEditing, setIsEditing] = React.useState(!initialCard);
  const [cardholderName, setCardholderName] = React.useState("");
  const [baseStripeStyle, setBaseStripeStyle] = React.useState<null | StripeElementStyleVariant>(null);

  const handleSubmit = asyncVoid(async () => {
    if (!stripe || !elements) return;

    const cardElement = elements.getElement(CardElement);
    if (!cardElement) return;

    setIsSubmitting(true);

    try {
      const { paymentMethod, error } = await stripe.createPaymentMethod({
        type: "card",
        card: cardElement,
        ...(cardholderName ? { billing_details: { name: cardholderName } } : {}),
      });

      if (error) {
        showAlert(error.message ?? "Card verification failed", "error");
        setIsSubmitting(false);
        return;
      }

      const response = await request({
        method: "POST",
        url: Routes.save_refund_funding_card_settings_payments_path(),
        accept: "json",
        data: {
          stripe_payment_method_id: paymentMethod.id,
          card_data_handling_mode: "stripejs.0",
        },
      });

      const result = cast<{ success: boolean; error?: string; credit_card?: NonNullable<RefundFundingCard> }>(
        await response.json(),
      );

      if (result.success && result.credit_card) {
        showAlert("Backup payment method saved successfully!", "success");
        setSavedCard(result.credit_card);
        setCardholderName("");
        setIsEditing(false);
      } else {
        showAlert(result.error ?? "Failed to save card", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred. Please try again.", "error");
    }

    setIsSubmitting(false);
  });

  const handleRemove = asyncVoid(async () => {
    // eslint-disable-next-line no-alert
    if (!window.confirm("Are you sure you want to remove your backup payment method?")) return;

    setIsSubmitting(true);

    try {
      const response = await request({
        method: "DELETE",
        url: Routes.remove_refund_funding_card_settings_payments_path(),
        accept: "json",
      });

      const result = cast<{ success: boolean }>(await response.json());

      if (result.success) {
        showAlert("Backup payment method removed", "success");
        setSavedCard(null);
        setIsEditing(true);
      } else {
        showAlert("Failed to remove card", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred. Please try again.", "error");
    }

    setIsSubmitting(false);
  });

  return (
    <section id="refund-payment-method" className="p-4! md:p-8!">
      <header>
        <h2>Refund payment method</h2>
        <p className="text-muted">
          Add a backup card to automatically cover refunds when your Gumroad balance is too low. You will only be
          charged if your balance cannot cover the refund amount.
        </p>
      </header>

      <div className="flex flex-col gap-5">
        {savedCard && !isEditing ? (
          <div className="flex flex-col gap-4">
            <div className="input read-only" aria-label="Saved backup card">
              <Icon name="outline-credit-card" />
              <span>{savedCard.visual}</span>
              <span style={{ marginLeft: "auto" }}>
                {savedCard.expiry_month.toString().padStart(2, "0")}/{savedCard.expiry_year.toString().slice(-2)}
              </span>
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
        ) : (
          <>
            <fieldset>
              <label htmlFor="refund_cardholder_name">Name on card</label>
              <input
                id="refund_cardholder_name"
                type="text"
                placeholder="Full name"
                value={cardholderName}
                disabled={isFormDisabled || isSubmitting}
                onChange={(e) => setCardholderName(e.target.value)}
              />
            </fieldset>
            <fieldset>
              <label htmlFor="refund_card_element">Card information</label>
              <div className="input">
                {baseStripeStyle == null ? (
                  <input
                    ref={(el) => {
                      if (el == null) return;
                      const inputStyle = window.getComputedStyle(el);
                      const color = getCssVariable("color").split(" ").join(",");
                      const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                      setBaseStripeStyle({
                        fontFamily: inputStyle.fontFamily,
                        color: inputStyle.color,
                        iconColor: placeholderColor,
                        "::placeholder": { color: placeholderColor },
                      });
                    }}
                  />
                ) : null}
                <CardElement
                  className="flex-1"
                  id="refund_card_element"
                  options={{
                    style: { base: baseStripeStyle ?? {} },
                    hidePostalCode: true,
                    hideIcon: true,
                    disabled: isFormDisabled || isSubmitting,
                  }}
                />
              </div>
            </fieldset>
            {!isFormDisabled ? (
              <div className="flex gap-4">
                <Button color="accent" onClick={handleSubmit} disabled={isSubmitting}>
                  {isSubmitting ? "Saving..." : savedCard ? "Update card" : "Save card"}
                </Button>
                {savedCard ? (
                  <Button outline onClick={() => setIsEditing(false)} disabled={isSubmitting}>
                    Cancel
                  </Button>
                ) : null}
              </div>
            ) : null}
          </>
        )}
      </div>
    </section>
  );
};

export const RefundPaymentMethodSection = ({
  initialCard,
  isFormDisabled,
}: {
  initialCard: RefundFundingCard;
  isFormDisabled: boolean;
}) => {
  const [stripePromise] = React.useState(getStripeInstance);
  const font = useFont();
  const stripeFonts = [{ family: font.name, src: `url(${font.url})` }];

  return (
    <Elements stripe={stripePromise} options={{ fonts: stripeFonts, locale: "en" }}>
      <RefundPaymentMethodForm initialCard={initialCard} isFormDisabled={isFormDisabled} />
    </Elements>
  );
};
