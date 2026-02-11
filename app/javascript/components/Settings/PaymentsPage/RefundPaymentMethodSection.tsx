import { CardElement, useElements, useStripe } from "@stripe/react-stripe-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";
import { getCssVariable } from "$app/utils/styles";

import { Button } from "$app/components/Button";
import { StripeElementsProvider } from "$app/components/Checkout/CreditCardInput";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

export type RefundPaymentMethod = {
  enabled: boolean;
  credit_card: {
    visual: string;
    card_type: string;
    expiry_month: number;
    expiry_year: number;
  } | null;
};

const RefundPaymentMethodForm = ({
  refundPaymentMethod,
  isFormDisabled,
}: {
  refundPaymentMethod: RefundPaymentMethod;
  isFormDisabled: boolean;
}) => {
  const stripe = useStripe();
  const elements = useElements();
  const [zipCode, setZipCode] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [savedCard, setSavedCard] = React.useState(refundPaymentMethod.credit_card);
  const [isEditing, setIsEditing] = React.useState(!refundPaymentMethod.enabled);
  const [confirmingRemove, setConfirmingRemove] = React.useState(false);
  const [stripeStyle, setStripeStyle] = React.useState<Record<string, unknown> | null>(null);

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
          card_data_handling_mode: "stripejs.0",
        },
      });

      const result = cast<{ success: boolean; error?: string; credit_card?: RefundPaymentMethod["credit_card"] }>(
        await response.json(),
      );

      if (result.success && result.credit_card) {
        showAlert("Refund payment method saved successfully!", "success");
        setSavedCard(result.credit_card);
        setIsEditing(false);
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
        setIsEditing(true);
      } else {
        showAlert(result.error || "Failed to remove card", "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred. Please try again.", "error");
    }

    setIsSubmitting(false);
  });

  return (
    <section id="refund-payment-method" className="p-4 md:p-8">
      <header>
        <h2>Refund payment method</h2>
        <p className="text-muted">
          Add a card to automatically cover refunds when your Gumroad balance is too low. You&apos;ll only be charged if
          your balance can&apos;t cover the refund amount.{" "}
          <a href="/help/article/refunds" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </p>
      </header>

      <div className="flex flex-col gap-5">
        {savedCard && !isEditing ? (
          <div className="flex flex-col gap-4">
            <Fieldset>
              <FieldsetTitle>Card information</FieldsetTitle>
              <InputGroup readOnly>
                <Icon name="outline-credit-card" />
                <Input readOnly value={`•••• •••• •••• ${savedCard.visual}`} />
                <span className="text-muted">
                  {savedCard.expiry_month.toString().padStart(2, "0")}/{savedCard.expiry_year.toString().slice(-2)}
                </span>
              </InputGroup>
            </Fieldset>
            {!isFormDisabled ? (
              <div className="flex gap-4">
                <Button outline onClick={() => setIsEditing(true)} disabled={isSubmitting}>
                  Change card
                </Button>
                <Button outline color="danger" onClick={() => setConfirmingRemove(true)} disabled={isSubmitting}>
                  Remove card
                </Button>
              </div>
            ) : null}
          </div>
        ) : (
          <>
            <Fieldset>
              <FieldsetTitle>ZIP / Postal code</FieldsetTitle>
              <Input
                type="text"
                id="refund_zip_code"
                placeholder="12345"
                value={zipCode}
                onChange={(e) => setZipCode(e.target.value)}
                disabled={isFormDisabled || isSubmitting}
              />
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>Card information</FieldsetTitle>
              <InputGroup disabled={isFormDisabled || isSubmitting}>
                <Icon name="outline-credit-card" />
                <div style={{ flex: 1 }}>
                  {stripeStyle == null ? (
                    <input
                      ref={(el) => {
                        if (el == null) return;
                        const inputStyle = window.getComputedStyle(el);
                        const color = getCssVariable("color").split(" ").join(",");
                        const placeholderColor = `rgb(${color}, ${getCssVariable("gray-3")})`;
                        setStripeStyle({
                          fontSize: "16px",
                          fontFamily: inputStyle.fontFamily,
                          color: inputStyle.color,
                          iconColor: placeholderColor,
                          "::placeholder": { color: placeholderColor },
                        });
                      }}
                    />
                  ) : null}
                  <CardElement
                    options={{
                      style: { base: stripeStyle ?? {} },
                      hideIcon: true,
                      hidePostalCode: true,
                      disabled: isFormDisabled || isSubmitting,
                    }}
                  />
                </div>
              </InputGroup>
            </Fieldset>
            {!isFormDisabled ? (
              <div className="flex gap-4">
                <Button onClick={handleSubmit} disabled={isSubmitting || !zipCode}>
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
      {confirmingRemove ? (
        <Modal
          open
          onClose={() => setConfirmingRemove(false)}
          title="Remove refund payment method?"
          footer={
            <>
              <Button onClick={() => setConfirmingRemove(false)} disabled={isSubmitting}>
                Cancel
              </Button>
              <Button
                color="danger"
                onClick={() => {
                  setConfirmingRemove(false);
                  void handleRemove();
                }}
                disabled={isSubmitting}
              >
                Remove
              </Button>
            </>
          }
        >
          <h4>
            Are you sure you want to remove your refund payment method? Refunds that exceed your balance will no longer
            be covered automatically.
          </h4>
        </Modal>
      ) : null}
    </section>
  );
};

export const RefundPaymentMethodSection = ({
  refundPaymentMethod,
  isFormDisabled,
}: {
  refundPaymentMethod: RefundPaymentMethod;
  isFormDisabled: boolean;
}) => (
  <StripeElementsProvider>
    <RefundPaymentMethodForm refundPaymentMethod={refundPaymentMethod} isFormDisabled={isFormDisabled} />
  </StripeElementsProvider>
);
