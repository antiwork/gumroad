import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";

import { PayoutCreditCard } from "$app/components/server-components/PayoutPage/CreditCard";
import { PayoutDebitCardData } from "$app/components/server-components/Settings/PaymentsPage";

const DebitCardSection = ({
  isFormDisabled,
  hasConnectedStripe,
  feeInfoText,
  savedCard,
  setDebitCard,
}: {
  isFormDisabled: boolean;
  hasConnectedStripe: boolean;
  feeInfoText: string;
  savedCard: SavedCreditCard | null;
  setDebitCard: (debitCard: PayoutDebitCardData) => void;
}) => (
  <>
    <div className="whitespace-pre-line">{feeInfoText}</div>
    <section className="override grid gap-8">
      <PayoutCreditCard saved_card={savedCard} is_form_disabled={isFormDisabled} setDebitCard={setDebitCard} />
    </section>
    {hasConnectedStripe ? (
      <section>
        <div role="alert" className="warning">
          You cannot change your payout method to card because you have a stripe account connected.
        </div>
      </section>
    ) : null}
  </>
);
export default DebitCardSection;
