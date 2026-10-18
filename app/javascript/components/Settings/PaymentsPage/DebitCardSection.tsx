import * as React from "react";

import { SavedCreditCard } from "$app/parsers/card";
import type { PayoutDebitCardData } from "$app/types/payments";

import { FeeInfoDetails, type FeeInfo } from "$app/components/FeeInfo";
import { PayoutCreditCard } from "$app/components/PayoutPage/CreditCard";
import {
  PayoutRailSetupNotice,
  type PayoutRailSetup,
} from "$app/components/Settings/PaymentsPage/StripeConnectSection";
import { Alert } from "$app/components/ui/Alert";

const DebitCardSection = ({
  isFormDisabled,
  hasConnectedStripe,
  payoutRailSetup,
  feeInfo,
  savedCard,
  setDebitCard,
}: {
  isFormDisabled: boolean;
  hasConnectedStripe: boolean;
  payoutRailSetup?: PayoutRailSetup | undefined;
  feeInfo: FeeInfo;
  savedCard: SavedCreditCard | null;
  setDebitCard: (debitCard: PayoutDebitCardData) => void;
}) => (
  <>
    <FeeInfoDetails feeInfo={feeInfo} />
    <section className="grid gap-8">
      <PayoutCreditCard saved_card={savedCard} is_form_disabled={isFormDisabled} setDebitCard={setDebitCard} />
    </section>
    {hasConnectedStripe ? (
      <section>
        {payoutRailSetup ? (
          <PayoutRailSetupNotice payoutRailSetup={payoutRailSetup} payoutType="debit card" />
        ) : (
          <Alert variant="warning">
            You cannot change your payout method to card because you have a stripe account connected.
          </Alert>
        )}
      </section>
    ) : null}
  </>
);
export default DebitCardSection;
