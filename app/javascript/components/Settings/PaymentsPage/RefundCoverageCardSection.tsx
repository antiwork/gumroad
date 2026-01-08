import { StripeCardElement, StripeCardElementChangeEvent } from "@stripe/stripe-js";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { prepareCardPaymentMethodData, prepareFutureCharges, confirmCardIfNeeded } from "$app/data/card_payment_method_data";
import { serializeCardParamsIntoQueryParamsObject } from "$app/data/payment_method_params";
import { SavedCreditCard } from "$app/parsers/card";
import { ComplianceInfo, User } from "$app/types/payments";
import { CurrencyCode, formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CreditCardInput } from "$app/components/Checkout/CreditCardInput";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Product } from "$app/components/Checkout/payment";

type Props = {
  refundCreditCard: SavedCreditCard | null;
  refundCoverageMaxAmountCents: number;
  cardDataHandlingMode: string | null;
  user: User;
  complianceInfo: ComplianceInfo;
  isFormDisabled: boolean;
};

const RefundCoverageCardSection = ({
  refundCreditCard,
  refundCoverageMaxAmountCents,
  cardDataHandlingMode,
  user,
  complianceInfo,
  isFormDisabled,
}: Props) => {
  const [savedCard, setSavedCard] = React.useState(refundCreditCard);
  const [isEditing, setIsEditing] = React.useState(!refundCreditCard);
  const [cardElement, setCardElement] = React.useState<StripeCardElement | null>(null);
  const [isCardComplete, setIsCardComplete] = React.useState(false);
  const [cardError, setCardError] = React.useState<string | null>(null);
  const [isSaving, setIsSaving] = React.useState(false);
  const [isRemoving, setIsRemoving] = React.useState(false);

  React.useEffect(() => {
    setSavedCard(refundCreditCard);
    setIsEditing(!refundCreditCard);
  }, [refundCreditCard]);

  const resetCardInput = () => {
    setCardElement(null);
    setIsCardComplete(false);
    setCardError(null);
  };

  const startEditing = () => {
    setIsEditing(true);
    resetCardInput();
  };

  const cancelEditing = () => {
    setIsEditing(false);
    resetCardInput();
  };

  const handleCardChange = (event: StripeCardElementChangeEvent) => {
    setIsCardComplete(event.complete);
    setCardError(event.error?.message ?? null);
  };

  const cardholderName = React.useMemo(() => {
    const personalName = [complianceInfo.first_name, complianceInfo.last_name].filter(Boolean).join(" ").trim();
    return (complianceInfo.is_business ? complianceInfo.business_name : personalName) || personalName || user.email;
  }, [complianceInfo, user.email]);

  const billingZipCode = complianceInfo.is_business ? complianceInfo.business_zip_code : complianceInfo.zip_code;
  const coverageCurrency = cast<CurrencyCode>(user.payout_currency ?? "usd");
  const formattedCoverageLimit = formatPriceCentsWithCurrencySymbol(coverageCurrency, refundCoverageMaxAmountCents, {
    symbolFormat: "short",
    noCentsIfWhole: true,
  });

  const saveCard = asyncVoid(async () => {
    if (!cardElement || !isCardComplete) {
      showAlert("Enter a complete card before saving.", "error");
      return;
    }

    setIsSaving(true);
    try {
      const paymentMethodData = await prepareCardPaymentMethodData({
        cardElement,
        email: user.email,
        name: cardholderName,
        ...(billingZipCode ? { zipCode: billingZipCode } : {}),
      });

      if (paymentMethodData.status === "error") {
        showAlert(paymentMethodData.stripe_error.message || "Please check your card details and try again.", "error");
        return;
      }

      // Only `price` is used by the setup intent endpoint to size mandates for some cards.
      const products = [cast<Product>({ price: refundCoverageMaxAmountCents })];
      const cardParams = await prepareFutureCharges({
        products,
        cardParams: paymentMethodData,
      }).then(confirmCardIfNeeded);

      if (cardParams.status === "error") {
        showAlert(cardParams.stripe_error.message || "Please check your card details and try again.", "error");
        return;
      }

      const response = await request({
        method: "POST",
        url: Routes.refund_credit_card_settings_payments_path(),
        accept: "json",
        data: {
          ...serializeCardParamsIntoQueryParamsObject(cardParams),
          ...(cardDataHandlingMode ? { card_data_handling_mode: cardDataHandlingMode } : {}),
        },
      });
      const responseData = cast<
        { success: true; refund_credit_card: SavedCreditCard } | { success: false; error_message: string }
      >(await response.json());

      if (!response.ok || !responseData.success) {
        throw new ResponseError("error_message" in responseData ? responseData.error_message : "Sorry, something went wrong.");
      }

      setSavedCard(responseData.refund_credit_card);
      setIsEditing(false);
      resetCardInput();
      showAlert("Refund coverage card saved.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsSaving(false);
    }
  });

  const removeCard = asyncVoid(async () => {
    setIsRemoving(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.remove_refund_credit_card_settings_payments_path(),
        accept: "json",
      });
      if (!response.ok) {
        const responseData = cast<{ error: string }>(await response.json());
        throw new ResponseError(responseData.error);
      }
      setSavedCard(null);
      setIsEditing(true);
      resetCardInput();
      showAlert("Refund coverage card removed.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsRemoving(false);
    }
  });

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Refund coverage card</h2>
      </header>
      <div className="flex flex-col gap-4">
        <p>
          When a refund is larger than your Gumroad balance, we&apos;ll charge this card for the shortfall so you can
          refund instantly.
        </p>
        <Alert variant="info">We only charge this card when needed, up to {formattedCoverageLimit} per refund.</Alert>
        {savedCard && !isEditing ? (
          <>
            <div className="input read-only" aria-label="Refund coverage card">
              <Icon name="outline-credit-card" />
              <span>{savedCard.number}</span>
              <span style={{ marginLeft: "auto" }}>{savedCard.expiration_date}</span>
            </div>
            <div className="flex gap-2">
              <Button outline onClick={startEditing} disabled={isFormDisabled}>
                Replace card
              </Button>
              <Button outline color="danger" onClick={removeCard} disabled={isFormDisabled || isRemoving}>
                {isRemoving ? "Removing..." : "Remove card"}
              </Button>
            </div>
          </>
        ) : (
          <>
            <CreditCardInput
              disabled={isFormDisabled}
              savedCreditCard={null}
              onReady={setCardElement}
              useSavedCard={false}
              setUseSavedCard={() => {}}
              invalid={Boolean(cardError)}
              onChange={handleCardChange}
            />
            {cardError ? <p className="text-danger">{cardError}</p> : null}
            <div className="flex gap-2">
              {savedCard ? (
                <Button outline onClick={cancelEditing} disabled={isFormDisabled || isSaving}>
                  Cancel
                </Button>
              ) : null}
              <Button onClick={saveCard} disabled={isFormDisabled || isSaving || !isCardComplete}>
                {isSaving ? "Saving..." : "Save card"}
              </Button>
            </div>
          </>
        )}
      </div>
    </section>
  );
};

export default RefundCoverageCardSection;
